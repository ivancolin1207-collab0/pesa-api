$ErrorActionPreference = "Stop"
$AppName = "Servicios_PESA_v1.0.0"
$DistDir = "dist\$AppName"
$Exe     = "$DistDir\$AppName.exe"

Write-Host "=== Servicios PESA - Build Produccion (Render) ===" -ForegroundColor Cyan

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
cmd /c "attrib -r -s -h build /s /d 2>nul & rmdir /s /q build 2>nul & attrib -r -s -h dist\$AppName /s /d 2>nul & rmdir /s /q dist\$AppName 2>nul"

# 5. Empaquetar con PyInstaller
Write-Host "[5/6] Empaquetando con PyInstaller..." -ForegroundColor Yellow
python -m PyInstaller --noconfirm "Servicios_PESA_v1.0.0.spec"

# 6. Post-proceso: copiar .env al dist y a Ejecutables\Windows
Write-Host "[6/6] Finalizando y copiando a Ejecutables..." -ForegroundColor Yellow
Copy-Item ".env.production" "$DistDir\.env" -Force
Write-Host "    .env de produccion copiado al dist" -ForegroundColor Green

# Resultado
if (Test-Path $Exe) {
    $sizeMB = [Math]::Round((Get-Item $Exe).Length / 1MB, 2)
    $fullPath = (Get-Item $Exe).FullName
    Write-Host ""
    Write-Host "=== BUILD EXITOSO ===" -ForegroundColor Green
    Write-Host "Ejecutable : $fullPath" -ForegroundColor Green
    Write-Host "Tamano     : $sizeMB MB" -ForegroundColor Green
    Write-Host "Carpeta    : $(Resolve-Path $DistDir)" -ForegroundColor Green

    # Copiar a Ejecutables\Windows
    $targetDir = "..\Ejecutables\Windows"
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force }
    Copy-Item "$DistDir\*" $targetDir -Recurse -Force
    Copy-Item $Exe "$targetDir\Servicios_PESA.exe" -Force
    Copy-Item $Exe "$targetDir\Servicios_PESA_v1.0.0.exe" -Force
    Write-Host "Copia completada en $targetDir" -ForegroundColor Green
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
