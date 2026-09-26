$ErrorActionPreference = "Stop"
$AppName = "Servicios_PESA_v1.0.0"
$DistDir = "dist\$AppName"
$Exe     = "$DistDir\$AppName.exe"

Write-Host "=== Servicios PESA — Build Produccion (Render) ===" -ForegroundColor Cyan

# 1. Verificar entorno
Write-Host "[1/6] Verificando entorno..." -ForegroundColor Yellow
python --version
python -m PyInstaller --version

# 2. Verificar API Render
Write-Host "[2/6] Verificando API Render..." -ForegroundColor Yellow
try {
    $res = Invoke-WebRequest -Uri "https://pesa-api-za9i.onrender.com/health" `
           -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
    Write-Host "    API Render: HTTP $($res.StatusCode)" -ForegroundColor Green
} catch {
    Write-Host "    Sin conexion a Render (el exe se genera igual)" -ForegroundColor DarkYellow
}

# 3. Activar .env de produccion
Write-Host "[3/6] Activando .env de produccion (Render)..." -ForegroundColor Yellow
if (Test-Path ".env") { Copy-Item ".env" ".env.local_backup" -Force }
Copy-Item ".env.production" ".env" -Force
Write-Host "    .env -> Render PostgreSQL OK" -ForegroundColor Green

# 4. Limpiar build anterior
Write-Host "[4/6] Limpiando builds anteriores..." -ForegroundColor Yellow
if (Test-Path "build")         { Remove-Item "build"         -Recurse -Force }
if (Test-Path "dist\$AppName") { Remove-Item "dist\$AppName" -Recurse -Force }

# 5. Empaquetar con PyInstaller
Write-Host "[5/6] Empaquetando con PyInstaller (2-5 min)..." -ForegroundColor Yellow
python -m PyInstaller --noconfirm "Servicios_PESA_v1.0.0.spec"

# 6. Post-proceso: copiar .env al dist
Write-Host "[6/6] Finalizando..." -ForegroundColor Yellow
Copy-Item ".env.production" "$DistDir\.env" -Force
Write-Host "    .env de produccion copiado al dist" -ForegroundColor Green

# Resultado
if (Test-Path $Exe) {
    $sizeKB = [Math]::Round((Get-Item $Exe).Length / 1MB, 1)
    $fullPath = (Get-Item $Exe).FullName
    Write-Host ""
    Write-Host "=== BUILD EXITOSO ===" -ForegroundColor Green
    Write-Host "Ejecutable : $fullPath" -ForegroundColor Green
    Write-Host "Tamano     : $sizeKB MB" -ForegroundColor Green
    Write-Host "Carpeta    : $(Resolve-Path $DistDir)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Para distribuir: copia TODA la carpeta '$DistDir' al equipo destino." -ForegroundColor Cyan
} else {
    Write-Host "ERROR: No se genero el ejecutable. Revisa la salida arriba." -ForegroundColor Red
    exit 1
}

# Restaurar .env de desarrollo
if (Test-Path ".env.local_backup") {
    Copy-Item ".env.local_backup" ".env" -Force
    Remove-Item ".env.local_backup" -Force
    Write-Host ".env de desarrollo restaurado." -ForegroundColor Gray
}
