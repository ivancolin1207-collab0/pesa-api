"""
Servicio de Folios — capa delgada sobre FolioManager.
Punto de entrada recomendado para la UI al generar folios.
"""
from models.folio_manager import FolioManager


class FolioService:
    """Fachada del servicio de generación de folios."""

    @staticmethod
    def nuevo_folio_os(anio: int | None = None) -> str:
        """Genera el siguiente folio de Orden de Servicio."""
        return FolioManager.get_next_folio("OS", anio)

    @staticmethod
    def nuevo_folio_rma(anio: int | None = None) -> str:
        """Genera el siguiente folio de Remisión."""
        return FolioManager.get_next_folio("RMA", anio)

    @staticmethod
    def nuevo_folio_re(anio: int | None = None) -> str:
        """Genera el siguiente folio de Revisión."""
        return FolioManager.get_next_folio("RE", anio)

    @staticmethod
    def nuevo_folio_lv(anio: int | None = None) -> str:
        """Genera el siguiente folio de Levantamiento Metrológico y Logística de Pesas."""
        return FolioManager.get_next_folio("LV", anio)


    @staticmethod
    def get_resumen() -> list[dict]:
        """Resumen de consecutivos por tipo y año."""
        return FolioManager.get_resumen_folios()


folio_service = FolioService()
