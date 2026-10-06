import json
import logging
import os
import re
import secrets
import sqlite3
import uuid
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path

from flask import (
    Flask,
    abort,
    current_app,
    flash,
    g,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
from werkzeug.security import check_password_hash, generate_password_hash


LOGGER = logging.getLogger("novashop.security")
if not LOGGER.handlers:
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter("%(message)s"))
    LOGGER.addHandler(handler)
LOGGER.setLevel(logging.INFO)
LOGGER.propagate = False


def _default_lab_mode() -> bool:
    explicit_value = os.getenv("NOVASHOP_LAB_MODE")
    if explicit_value is not None:
        return explicit_value.lower() in {"1", "true", "yes", "on"}

    # Local development is vulnerable by default. Azure App Service is remediated
    # unless the operator explicitly enables the lab after applying IP restrictions.
    return not bool(os.getenv("WEBSITE_INSTANCE_ID") or os.getenv("WEBSITE_SITE_NAME"))


def create_app(test_config=None):
    app = Flask(__name__, instance_relative_config=True)
    Path(app.instance_path).mkdir(parents=True, exist_ok=True)

    app.config.from_mapping(
        SECRET_KEY=os.getenv("NOVASHOP_SESSION_SECRET") or secrets.token_urlsafe(32),
        DATABASE=os.getenv(
            "NOVASHOP_DB", str(Path(app.instance_path) / "novashop.sqlite3")
        ),
        LAB_MODE=_default_lab_mode(),
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    if test_config:
        app.config.update(test_config)

    app.teardown_appcontext(close_db)

    @app.before_request
    def prepare_request():
        g.request_id = str(uuid.uuid4())
        user_id = session.get("user_id")
        g.user = (
            get_db().execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()
            if user_id
            else None
        )

    @app.after_request
    def record_http_request(response):
        response.headers["X-Lab-Request-ID"] = g.get("request_id", "unknown")
        _emit_event(
            "http_request",
            "completed",
            method=request.method,
            path=request.path,
            query=request.query_string.decode("utf-8", errors="replace")[:500],
            status=response.status_code,
            user=g.user["username"] if g.get("user") else None,
        )
        return response

    @app.context_processor
    def inject_lab_context():
        return {"lab_mode": app.config["LAB_MODE"]}

    @app.template_filter("money")
    def format_money(cents):
        return f"{cents / 100:.2f} EUR"

    @app.route("/")
    def index():
        products = get_db().execute("SELECT * FROM products ORDER BY id").fetchall()
        return render_template("index.html", products=products)

    @app.route("/search")
    def search():
        term = request.args.get("q", "")
        rows = []
        executed_query = None
        error = None
        injection_pattern = bool(
            re.search(r"('|--|/\*|\bunion\b|\bor\s+\d+\s*=\s*\d+)", term, re.I)
        )

        try:
            if app.config["LAB_MODE"]:
                # INTENTIONAL LAB VULNERABILITY: untrusted input is concatenated.
                executed_query = (
                    "SELECT * FROM products "
                    f"WHERE name LIKE '%{term}%' OR description LIKE '%{term}%' "
                    "ORDER BY name"
                )
                rows = get_db().execute(executed_query).fetchall()
            else:
                pattern = f"%{term}%"
                rows = get_db().execute(
                    "SELECT * FROM products "
                    "WHERE name LIKE ? OR description LIKE ? ORDER BY name",
                    (pattern, pattern),
                ).fetchall()

            if injection_pattern and app.config["LAB_MODE"]:
                search_outcome = "candidate_injection_executed"
            elif injection_pattern:
                search_outcome = "candidate_injection_parameterized"
            else:
                search_outcome = "completed"
            _security_event(
                "product_search",
                search_outcome,
                search_term=term[:300],
                matched_products=len(rows),
                signature_match=injection_pattern,
                query_control="concatenated" if app.config["LAB_MODE"] else "parameterized",
            )
        except sqlite3.Error as exc:
            error = str(exc) if app.config["LAB_MODE"] else "The search could not be completed."
            _security_event(
                "product_search",
                "database_error",
                search_term=term[:300],
                signature_match=injection_pattern,
                database_error=type(exc).__name__,
            )

        return render_template(
            "search.html",
            products=rows,
            term=term,
            executed_query=executed_query,
            error=error,
        )

    @app.route("/products/<int:product_id>")
    def product(product_id):
        db = get_db()
        selected_product = db.execute(
            "SELECT * FROM products WHERE id = ?", (product_id,)
        ).fetchone()
        if selected_product is None:
            abort(404)
        reviews = db.execute(
            "SELECT reviews.*, users.username "
            "FROM reviews JOIN users ON users.id = reviews.user_id "
            "WHERE product_id = ? ORDER BY reviews.id DESC",
            (product_id,),
        ).fetchall()
        return render_template(
            "product.html", product=selected_product, reviews=reviews
        )

    @app.post("/products/<int:product_id>/reviews")
    @login_required
    def add_review(product_id):
        db = get_db()
        if db.execute("SELECT id FROM products WHERE id = ?", (product_id,)).fetchone() is None:
            abort(404)

        body = request.form.get("body", "").strip()[:2000]
        if not body:
            flash("Write a review before submitting it.", "error")
            return redirect(url_for("product", product_id=product_id))

        contains_markup = bool(re.search(r"<\s*(script|img|svg|iframe|[^>]+on\w+)", body, re.I))
        db.execute(
            "INSERT INTO reviews (product_id, user_id, body, created_at) VALUES (?, ?, ?, ?)",
            (product_id, g.user["id"], body, datetime.now(timezone.utc).isoformat()),
        )
        db.commit()
        if contains_markup and app.config["LAB_MODE"]:
            review_outcome = "candidate_stored_xss_rendered_unsafe"
        elif contains_markup:
            review_outcome = "active_markup_output_encoded"
        else:
            review_outcome = "accepted"
        _security_event(
            "review_submitted",
            review_outcome,
            product_id=product_id,
            content_length=len(body),
            contains_active_markup=contains_markup,
            rendering_control="unsafe" if app.config["LAB_MODE"] else "autoescaped",
        )
        flash("Review published.", "success")
        return redirect(url_for("product", product_id=product_id))

    @app.route("/login", methods=("GET", "POST"))
    def login():
        if request.method == "POST":
            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            user = get_db().execute(
                "SELECT * FROM users WHERE username = ?", (username,)
            ).fetchone()
            success = bool(user and check_password_hash(user["password_hash"], password))
            _security_event(
                "login_attempt",
                "success" if success else "failure",
                attempted_username=username[:100],
            )
            if success:
                session.clear()
                session["user_id"] = user["id"]
                flash(f"Welcome back, {user['display_name']}.", "success")
                return redirect(url_for("account"))
            flash("Invalid username or password.", "error")
        return render_template("login.html")

    @app.get("/logout")
    def logout():
        session.clear()
        flash("Session closed.", "success")
        return redirect(url_for("index"))

    @app.get("/account")
    @login_required
    def account():
        orders = get_db().execute(
            "SELECT * FROM orders WHERE user_id = ? ORDER BY created_at DESC",
            (g.user["id"],),
        ).fetchall()
        return render_template("account.html", orders=orders)

    @app.get("/orders/<int:order_id>")
    @login_required
    def order(order_id):
        db = get_db()
        selected_order = db.execute(
            "SELECT orders.*, users.username AS owner_username, "
            "users.display_name AS owner_display_name "
            "FROM orders JOIN users ON users.id = orders.user_id "
            "WHERE orders.id = ?",
            (order_id,),
        ).fetchone()
        if selected_order is None:
            abort(404)

        is_owner = selected_order["user_id"] == g.user["id"]
        is_admin = g.user["role"] == "admin"
        if not app.config["LAB_MODE"] and not (is_owner or is_admin):
            _security_event(
                "order_access",
                "blocked_by_authorization",
                order_id=order_id,
                order_owner=selected_order["owner_username"],
                requester=g.user["username"],
            )
            abort(403)

        outcome = "authorized"
        if app.config["LAB_MODE"] and not (is_owner or is_admin):
            outcome = "allowed_without_ownership_check"
        _security_event(
            "order_access",
            outcome,
            order_id=order_id,
            order_owner=selected_order["owner_username"],
            requester=g.user["username"],
        )

        items = db.execute(
            "SELECT order_items.*, products.name "
            "FROM order_items JOIN products ON products.id = order_items.product_id "
            "WHERE order_id = ? ORDER BY order_items.id",
            (order_id,),
        ).fetchall()
        return render_template("order.html", order=selected_order, items=items)

    @app.get("/health")
    def health():
        return jsonify(status="ok", lab_mode=app.config["LAB_MODE"])

    @app.errorhandler(403)
    def forbidden(_error):
        return render_template("error.html", code=403, message="Access denied."), 403

    @app.errorhandler(404)
    def not_found(_error):
        return render_template("error.html", code=404, message="Page not found."), 404

    @app.cli.command("reset-db")
    def reset_db_command():
        db = get_db()
        db.executescript(
            "DROP TABLE IF EXISTS order_items;"
            "DROP TABLE IF EXISTS orders;"
            "DROP TABLE IF EXISTS reviews;"
            "DROP TABLE IF EXISTS products;"
            "DROP TABLE IF EXISTS users;"
        )
        db.commit()
        init_db()
        print("NovaShop database reset with fictional data.")

    with app.app_context():
        init_db()

    return app


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(current_app.config["DATABASE"])
        g.db.row_factory = sqlite3.Row
    return g.db


def close_db(_error=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    from flask import current_app

    db = get_db()
    with current_app.open_resource("schema.sql") as schema_file:
        db.executescript(schema_file.read().decode("utf-8"))

    if db.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 0:
        users = [
            (1, "alice.finance", "Alice Romero", "customer", "AliceLab!2026"),
            (2, "bob.hr", "Bob Navarro", "customer", "BobLab!2026"),
            (3, "charlie.dev", "Charlie Vega", "customer", "CharlieLab!2026"),
            (4, "shop.admin", "Morgan Admin", "admin", "AdminLab!2026"),
        ]
        db.executemany(
            "INSERT INTO users (id, username, display_name, role, password_hash) "
            "VALUES (?, ?, ?, ?, ?)",
            [
                (user_id, username, display_name, role, generate_password_hash(password))
                for user_id, username, display_name, role, password in users
            ],
        )

        # LAB: credencial de dominio en claro dentro de una tabla de configuracion
        # heredada. Es el puente entre la SQLi y la reutilizacion de credenciales:
        # `secret` coincide con la contrasena real de charlie.dev en Active Directory.
        db.execute(
            "INSERT INTO integration_config (id, service, endpoint, account, secret, notes) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (
                1,
                "corp-ldap-sync",
                "ldap://dc01.novashop.local",
                "NOVASHOP\\charlie.dev",
                "Dev3loper2026!",
                "Legacy sync account. TODO: migrar a gMSA antes de produccion.",
            ),
        )

        db.executemany(
            "INSERT INTO products (id, name, description, price_cents, accent) "
            "VALUES (?, ?, ?, ?, ?)",
            [
                (1, "Orbit Headphones", "Wireless headphones for focused work.", 8990, "violet"),
                (2, "Pulse Keyboard", "Compact mechanical keyboard with quiet switches.", 7490, "cyan"),
                (3, "Nova Camera", "1080p camera for meetings and streaming.", 6490, "amber"),
                (4, "Arc Lamp", "Adjustable desk lamp with warm and cool modes.", 3990, "rose"),
                (5, "Cloud Mug", "Insulated mug for long incident-response shifts.", 2490, "green"),
                (6, "Signal Backpack", "Weather-resistant backpack for a 16-inch laptop.", 10990, "blue"),
            ],
        )

        db.executemany(
            "INSERT INTO orders (id, user_id, status, total_cents, shipping_address, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            [
                (1001, 1, "Shipped", 11380, "14 Fictional Street, Madrid", "2026-08-03T09:12:00+00:00"),
                (1002, 2, "Processing", 13880, "88 Training Avenue, Barcelona", "2026-08-05T15:44:00+00:00"),
                (1003, 3, "Delivered", 10480, "7 Demo Plaza, Valencia", "2026-08-01T11:20:00+00:00"),
            ],
        )
        db.executemany(
            "INSERT INTO order_items (order_id, product_id, quantity, unit_price_cents) "
            "VALUES (?, ?, ?, ?)",
            [
                (1001, 1, 1, 8990),
                (1001, 5, 1, 2390),
                (1002, 2, 1, 7490),
                (1002, 3, 1, 6390),
                (1003, 4, 2, 3990),
                (1003, 5, 1, 2500),
            ],
        )
        db.executemany(
            "INSERT INTO reviews (product_id, user_id, body, created_at) VALUES (?, ?, ?, ?)",
            [
                (1, 2, "Clear sound and comfortable during long calls.", "2026-08-04T10:00:00+00:00"),
                (2, 1, "Small, solid and pleasantly quiet.", "2026-08-06T17:30:00+00:00"),
            ],
        )
        db.commit()


def login_required(view):
    @wraps(view)
    def wrapped_view(**kwargs):
        if g.user is None:
            flash("Sign in to continue.", "error")
            return redirect(url_for("login"))
        return view(**kwargs)

    return wrapped_view


def _client_ip():
    forwarded = request.headers.get("X-Forwarded-For", "")
    return forwarded.split(",")[0].strip() if forwarded else request.remote_addr


def _security_event(event_type, outcome, **details):
    _emit_event(
        event_type,
        outcome,
        user=g.user["username"] if g.get("user") else None,
        **details,
    )


def _emit_event(event_type, outcome, **details):
    from flask import current_app

    event = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "kind": "novashop_security",
        "event_type": event_type,
        "outcome": outcome,
        "lab_mode": current_app.config["LAB_MODE"],
        "request_id": g.get("request_id", None),
        "client_ip": _client_ip() if request else None,
        **details,
    }
    LOGGER.info(json.dumps(event, ensure_ascii=False, default=str))


app = create_app()


if __name__ == "__main__":
    app.run(
        host=os.getenv("NOVASHOP_HOST", "127.0.0.1"),
        port=int(os.getenv("PORT", "5000")),
        debug=False,
    )
