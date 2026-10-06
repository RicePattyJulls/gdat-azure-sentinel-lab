# GDAT 2.0

Laboratorio reproducible de Microsoft Sentinel, Defender XDR, identidad,
telemetría y respuesta. Esta carpeta es la única raíz del proyecto.

## Por dónde empezar

1. Leer `gdat/BUILD_GDAT2.0.md`: guía operativa vigente de 21 fases.
2. Leer `biceps/README.md`: arquitectura, automatización y límites reales.
3. Entrar en `biceps/`, cargar secretos y ejecutar primero `./deploy.sh preview`.
4. Publicar la aplicación incluida con `./deploy.sh publicar-app`.

`gdat/BUILD_GDAT.md` es únicamente el historial original de 30 fases y no se
modifica. `biceps/novashop/` es la única copia activa de NovaShop.

## Árbol

```text
GDAT/
├── biceps/       infraestructura, scripts, KQL y NovaShop
├── gdat/         guía vigente, historial e imágenes
├── archive/      material del tenant anterior; no ejecutar sin revisión
├── artillery.md comandos auxiliares
└── readthiscloud.md checkpoint interno entre sesiones
```

Nunca se versionan `.env.local`, `.venv`, bases SQLite, cachés ni configuración
local de Azure. El material de `archive/` puede contener identificadores de un
tenant extinguido y no forma parte del procedimiento vigente.
