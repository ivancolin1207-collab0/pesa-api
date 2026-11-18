# -*- coding: utf-8 -*-
"""
utils_metrologia.py — Módulo compartido de extracción universal de CCA/DVE
y construcción de la plantilla institucional de correo con tabla HTML.
"""
from services.metrology import (
    extraer_cca_dve,
    armar_correo_institucional,
    construir_asunto_y_cuerpo_correo,
    formatear_linea_correo_orden,
    extraer_metadatos_equipo_de_pdf_bytes,
    limpiar_numero_regulatorio,
)

__all__ = [
    "extraer_cca_dve",
    "armar_correo_institucional",
    "construir_asunto_y_cuerpo_correo",
    "formatear_linea_correo_orden",
    "extraer_metadatos_equipo_de_pdf_bytes",
    "limpiar_numero_regulatorio",
]
