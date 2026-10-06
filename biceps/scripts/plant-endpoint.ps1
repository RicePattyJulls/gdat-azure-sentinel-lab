<#
    Fase 5 · Lo que se planta en el endpoint, no en el controlador

    Dos piezas que viven en MEMBER01 y no en DC01:

      1. El acceso remoto de charlie.dev. Remote Desktop Users es un grupo
         LOCAL de la maquina, no del dominio: de ahi Add-LocalGroupMember y no
         Add-ADGroupMember. El miembro si es una cuenta de dominio.
      2. Los datos sinteticos. El ultimo eslabon de la cadena necesita algo que
         robar, y la exfiltracion tiene que mover ficheros reales para que el
         tamano en StorageBlobLogs signifique algo.

    Idempotente: no duplica la pertenencia ni reescribe los ficheros si existen.
#>
[CmdletBinding()]
param(
    [string] $Netbios = 'NOVASHOP',
    [string] $CuentaRdp = 'charlie.dev',
    [string] $RutaDatos = 'C:\Datos_Financieros'
)

$ErrorActionPreference = 'Stop'

function Escribir($mensaje) {
    Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $mensaje)
}

# --- 1. Acceso remoto -------------------------------------------------------

$miembro = "$Netbios\$CuentaRdp"
$actuales = Get-LocalGroupMember -Group 'Remote Desktop Users' -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Name

if ($actuales -contains $miembro) {
    Escribir "$miembro ya esta en Remote Desktop Users."
}
else {
    Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $miembro
    Escribir "$miembro anadido a Remote Desktop Users."
}

# --- 2. Datos sinteticos ----------------------------------------------------

if (-not (Test-Path $RutaDatos)) {
    New-Item -Path $RutaDatos -ItemType Directory -Force | Out-Null
    Escribir "Directorio $RutaDatos creado."
}

$ficheros = @{
    'nominas_2026.csv'      = @(
        'empleado,departamento,salario_bruto,iban'
        'alice.finance,Finanzas,54000,ES9121000418450200051332'
        'bob.hr,Recursos Humanos,48000,ES7620770024003102575766'
        'david.sales,Ventas,51000,ES6000491500051234567892'
        'charlie.dev,Desarrollo,46000,ES1000492352082414205416'
    )
    'clientes_top.csv'      = @(
        'cliente,cif,facturacion_anual,contacto'
        'Comercial Iberia SL,B12345678,1250000,compras@iberia.example'
        'Distribuciones Norte,B87654321,890000,pedidos@norte.example'
        'Grupo Levante SA,A11223344,2100000,admin@levante.example'
    )
    'previsiones_Q4.csv'    = @(
        'linea,prevision,margen'
        'Retail,3400000,0.22'
        'Mayorista,1800000,0.17'
        'Online,950000,0.31'
    )
}

foreach ($nombre in $ficheros.Keys) {
    $destino = Join-Path $RutaDatos $nombre
    if (Test-Path $destino) {
        Escribir "$nombre ya existe."
        continue
    }
    $ficheros[$nombre] | Set-Content -Path $destino -Encoding UTF8
    Escribir "$nombre creado."
}

Escribir "Endpoint preparado. Datos en $RutaDatos."
