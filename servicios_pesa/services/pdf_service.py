"""
Servicio de generación de PDFs.
Replica el layout del formato físico "Toma de Datos" usando ReportLab.
(Fase 2 — Implementación pendiente)
"""
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

try:
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.units import cm
    from reportlab.platypus import SimpleDocTemplate, Table, TableStyle, Paragraph, Spacer
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib import colors
    REPORTLAB_AVAILABLE = True
except ImportError:
    REPORTLAB_AVAILABLE = False
    logger.warning("ReportLab no está instalado. Instalar con: pip install reportlab")


class PdfService:
    """
    Genera PDFs del formato "Toma de Datos" para cada OS.

    Requiere:
        pip install reportlab Pillow

    TODO (Fase 2):
        - Layout completo replicando el formato físico
        - Logo de Básculas PESA en encabezado
        - Tablas de pruebas metrológicas con formato
        - Sección de firmas con líneas
        - Pie de página con datos de contacto
    """

    def generate_os_pdf(
        self,
        os_data: dict,
        repetibilidad: list[dict],
        excentricidad: list[dict],
        exactitud: list[dict],
        output_path: Optional[str] = None,
    ) -> str:
        """
        Genera el PDF de una OS.

        Args:
            os_data:        Datos de la OS (de v_ordenes_servicio).
            repetibilidad:  Filas de det_repetibilidad.
            excentricidad:  Filas de det_excentricidad.
            exactitud:      Filas de det_exactitud.
            output_path:    Ruta de salida del PDF (opcional, genera temporal).

        Returns:
            Ruta del archivo PDF generado.
        """
        if not REPORTLAB_AVAILABLE:
            raise RuntimeError(
                "ReportLab no está instalado.\n"
                "Instalar con: pip install reportlab"
            )

        if output_path is None:
            import tempfile
            output_path = str(
                Path(tempfile.gettempdir()) / f"{os_data.get('folio_os', 'OS')}.pdf"
            )

        doc = SimpleDocTemplate(
            output_path,
            pagesize=letter,
            leftMargin=1.5 * cm,
            rightMargin=1.5 * cm,
            topMargin=1.5 * cm,
            bottomMargin=1.5 * cm,
        )

        styles = getSampleStyleSheet()
        story = []

        # TODO Fase 2: Implementar el layout completo
        # Por ahora genera un PDF básico con la información
        title_style = ParagraphStyle(
            "title", parent=styles["Title"],
            fontSize=18, spaceAfter=12,
        )
        story.append(Paragraph("TOMA DE DATOS — ORDEN DE SERVICIO", title_style))
        story.append(Paragraph(f"Folio: {os_data.get('folio_os', '—')}", styles["Heading2"]))
        story.append(Paragraph(f"Cliente: {os_data.get('cliente', '—')}", styles["Normal"]))
        story.append(Paragraph(f"Fecha: {os_data.get('fecha', '—')}", styles["Normal"]))
        story.append(Spacer(1, 1 * cm))
        story.append(Paragraph("Generación completa de PDF disponible en Fase 2.", styles["Normal"]))

        doc.build(story)
        logger.info(f"PDF generado: {output_path}")
        return output_path


pdf_service = PdfService()

# Re-exportar funciones del enrutador centralizado
try:
    from services.pdf_router import regenerar_pdf, regenerar_pdf_orden
except ImportError:
    try:
        from servicios_pesa.services.pdf_router import regenerar_pdf, regenerar_pdf_orden
    except ImportError:
        pass
