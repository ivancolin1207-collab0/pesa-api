"""
Servicio de Escaneos.
Gestiona la copia, renombrado y registro de archivos escaneados
desde los clientes hacia la carpeta centralizada en el servidor.
"""
import hashlib
import logging
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional

from config import SERVER_FILES_BASE, ESCANEOS_DIR
from database.connection import db_pool

logger = logging.getLogger(__name__)

EXTENSIONES_PERMITIDAS = {".pdf", ".jpg", ".jpeg", ".png", ".tif", ".tiff"}


class ScannerService:
    """
    Gestiona la adjunción de archivos escaneados a las OS.

    Flujo:
    1. Validar que el archivo de origen existe y es de tipo permitido.
    2. Construir el nombre de destino: OS-AA-NNN-ESCANEADO.{ext}
    3. Copiar el archivo a la ruta UNC del servidor.
    4. Calcular hash MD5 del archivo destino para integridad.
    5. Registrar en adjuntos_os y actualizar estado de OS a ESCANEADA.
    """

    def __init__(self, server_base: str = SERVER_FILES_BASE) -> None:
        self.server_base = Path(server_base)
        self.escaneos_dir = self.server_base / ESCANEOS_DIR

    def attach_scan(
        self,
        os_id: int,
        folio_os: str,
        source_path: str,
        tecnico_id: Optional[int] = None,
    ) -> dict:
        """
        Adjunta un archivo escaneado a una OS.

        Args:
            os_id:       ID de la Orden de Servicio en la BD.
            folio_os:    Folio de la OS (ej. 'OS-26-443').
            source_path: Ruta completa al archivo de origen en el cliente.
            tecnico_id:  ID del técnico que adjunta el archivo (opcional).

        Returns:
            Diccionario con la info del archivo adjuntado:
            {'nombre_archivo', 'ruta_completa', 'hash_md5', 'tamano_bytes'}

        Raises:
            FileNotFoundError: Si el archivo de origen no existe.
            ValueError:        Si la extensión no está permitida.
            OSError:           Si hay error al copiar el archivo (VPN caída, etc.).
        """
        source = Path(source_path)

        # 1. Validaciones
        if not source.exists():
            raise FileNotFoundError(f"El archivo no existe: {source_path}")

        ext = source.suffix.lower()
        if ext not in EXTENSIONES_PERMITIDAS:
            raise ValueError(
                f"Tipo de archivo no permitido: '{ext}'. "
                f"Permitidos: {', '.join(sorted(EXTENSIONES_PERMITIDAS))}"
            )

        # 2. Construir nombre y ruta de destino
        nombre_destino = f"{folio_os}-ESCANEADO{ext}"
        dest_dir = self._ensure_dest_dir()
        dest_path = dest_dir / nombre_destino

        # 3. Copiar archivo
        logger.info(f"Copiando '{source_path}' → '{dest_path}'")
        try:
            shutil.copy2(str(source), str(dest_path))
        except OSError as exc:
            raise OSError(
                f"Error al copiar el archivo al servidor.\n"
                f"Verifique que la VPN esté activa y la ruta '{self.server_base}' sea accesible.\n"
                f"Detalle: {exc}"
            ) from exc

        # 4. Calcular hash MD5
        md5 = self._calculate_md5(dest_path)
        tamano = dest_path.stat().st_size

        logger.info(
            f"Archivo copiado exitosamente: {nombre_destino} "
            f"({tamano} bytes, MD5={md5})"
        )

        # 5. Registrar en BD y actualizar estado
        self._register_in_db(
            os_id=os_id,
            nombre_archivo=nombre_destino,
            ruta_completa=str(dest_path),
            hash_md5=md5,
            tipo_archivo=ext.lstrip("."),
            tamano_bytes=tamano,
            tecnico_id=tecnico_id,
        )

        return {
            "nombre_archivo": nombre_destino,
            "ruta_completa": str(dest_path),
            "hash_md5": md5,
            "tamano_bytes": tamano,
        }

    def _ensure_dest_dir(self) -> Path:
        """Crea el directorio de destino si no existe."""
        try:
            self.escaneos_dir.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            raise OSError(
                f"No se puede acceder al directorio del servidor: {self.escaneos_dir}\n"
                f"Verifique la conexión VPN. Detalle: {exc}"
            ) from exc
        return self.escaneos_dir

    @staticmethod
    def _calculate_md5(file_path: Path, chunk_size: int = 65536) -> str:
        """Calcula el hash MD5 de un archivo."""
        hasher = hashlib.md5()
        with open(file_path, "rb") as f:
            while chunk := f.read(chunk_size):
                hasher.update(chunk)
        return hasher.hexdigest()

    @staticmethod
    def _register_in_db(
        os_id: int,
        nombre_archivo: str,
        ruta_completa: str,
        hash_md5: str,
        tipo_archivo: str,
        tamano_bytes: int,
        tecnico_id: Optional[int],
    ) -> None:
        """Registra el adjunto en la BD y actualiza el estado de la OS."""
        with db_pool.transaction() as conn:
            with conn.cursor() as cur:
                # Insertar o reemplazar adjunto existente
                cur.execute(
                    """
                    INSERT INTO adjuntos_os (
                        id_os, nombre_archivo, ruta_completa, hash_md5,
                        tipo_archivo, tamano_bytes, id_tecnico_cargador, fecha_adjunto
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, NOW())
                    ON CONFLICT (id_os) DO UPDATE SET
                        nombre_archivo        = EXCLUDED.nombre_archivo,
                        ruta_completa         = EXCLUDED.ruta_completa,
                        hash_md5              = EXCLUDED.hash_md5,
                        tipo_archivo          = EXCLUDED.tipo_archivo,
                        tamano_bytes          = EXCLUDED.tamano_bytes,
                        id_tecnico_cargador   = EXCLUDED.id_tecnico_cargador,
                        fecha_adjunto         = NOW()
                    """,
                    (os_id, nombre_archivo, ruta_completa, hash_md5,
                     tipo_archivo, tamano_bytes, tecnico_id),
                )

                # Actualizar estado de OS a ESCANEADA
                cur.execute(
                    "UPDATE ordenes_servicio SET estado = 'ESCANEADA' WHERE id = %s",
                    (os_id,),
                )

        logger.info(f"OS ID={os_id} marcada como ESCANEADA en BD.")

    def verify_server_access(self) -> bool:
        """Verifica que la ruta del servidor es accesible (VPN activa)."""
        return self.server_base.exists()


# Instancia singleton
scanner_service = ScannerService()
