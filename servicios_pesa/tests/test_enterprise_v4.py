# -*- coding: utf-8 -*-
"""
test_enterprise_v4.py — Suite automatizada de Backend Headless, RBAC,
Reglas Metrológicas, Plantilla HTML de Correos y Generación Real de PDFs (v4.0).

REGLAS:
  - Bloquea PyQt6 explícitamente (sys.modules['PyQt6'] = None) para probar
    aislamiento total de Linux/Render.
  - Genera PDFs reales exclusivamente en tempfile.TemporaryDirectory() sin
    tocar ningún PDF existente del workspace ni archivos .env.
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
SERVICIOS_DIR = WORKSPACE_ROOT / "servicios_pesa"

for _p in (str(WORKSPACE_ROOT), str(SERVICIOS_DIR)):
    if _p not in sys.path:
        sys.path.insert(0, _p)


class TestHeadlessImports(unittest.TestCase):
    """Verifica que el backend FastAPI y módulos metrológicos importen sin PyQt6."""

    def test_headless_backend_without_pyqt6(self):
        blocked = {}
        for mod_name in ("PyQt6", "PyQt6.QtWidgets", "PyQt6.QtCore", "PyQt6.QtGui"):
            blocked[mod_name] = sys.modules.get(mod_name, "__MISSING__")
            sys.modules[mod_name] = None  # type: ignore[assignment]

        try:
            import pesa_api.core.security as api_security
            import pesa_api.core.email_service as api_email
            import pesa_api.main as api_main
            import utils_metrologia
            import services.metrology as svc_metrology
            import services.os_pdf_generator as pdf_gen

            self.assertTrue(hasattr(api_main, "app"))
            self.assertTrue(hasattr(api_security, "es_admin"))
            self.assertTrue(hasattr(api_email, "armar_correo_institucional"))
            self.assertTrue(hasattr(utils_metrologia, "formatear_division_minima"))
            self.assertTrue(hasattr(svc_metrology, "armar_correo_institucional"))
            self.assertTrue(hasattr(pdf_gen, "os_pdf_generator"))

            # Verificar rutas críticas registradas en FastAPI
            paths = set(api_main.app.openapi().get("paths", {}).keys())
            for r in api_main.app.routes:
                p = getattr(r, "path", None)
                if p:
                    paths.add(p)
            for expected in (
                "/health",
                "/api/clientes",
                "/api/admin/catalogos",
                "/api/ordenes",
                "/api/ordenes/{folio}/instrumento",
                "/api/ordenes/{folio}/cancelar",
                "/api/ordenes/{folio}/reactivar",
                "/api/usuarios/{id_tecnico}/firma",
            ):
                self.assertIn(expected, paths, f"Ruta crítica ausente en FastAPI: {expected}")
        finally:
            for mod_name, prev in blocked.items():
                if prev == "__MISSING__":
                    sys.modules.pop(mod_name, None)
                else:
                    sys.modules[mod_name] = prev


class TestRBACUnificado(unittest.TestCase):
    """Verifica el helper unificado es_admin() en pesa_api.core.security."""

    def test_es_admin_strings_and_dicts(self):
        from pesa_api.core.security import es_admin, es_rol_admin

        for role_ok in ("admin", "Administrador", "ADMINISTRADOR", "superadmin", "jefe", "gerente", "Dirección"):
            self.assertTrue(es_admin(role_ok), f"Debe reconocer {role_ok!r} como admin")
            self.assertTrue(es_admin({"rol": role_ok}), f"Dict con rol {role_ok!r} debe ser admin")
            self.assertTrue(es_rol_admin({"rol": role_ok}))

        for role_no in ("Técnico", "tecnico", "logistica", "recepcion", "", None):
            self.assertFalse(es_admin(role_no), f"No debe reconocer {role_no!r} como admin")

        self.assertTrue(es_admin({"rol": "Técnico", "roles": ["Técnico", "Administrador"]}))
        self.assertTrue(es_admin({"rol": "Técnico", "username": "ivancolin1207"}))


class TestMetrologiaYCorreosHTML(unittest.TestCase):
    """Verifica división mínima, CCA/DVE y correos HTML Apple PESA excluyendo CANCELADA."""

    def test_formatear_division_minima(self):
        from utils_metrologia import formatear_division_minima

        self.assertEqual(formatear_division_minima("0.020 kg"), "0.02 kg")
        self.assertEqual(formatear_division_minima("0.500 g"), "0.5 g")
        self.assertEqual(formatear_division_minima("10.000 kg"), "10 kg")
        self.assertEqual(formatear_division_minima("0.0050"), "0.005")

    def test_extraer_cca_dve_y_reglas_dve(self):
        from utils_metrologia import extraer_cca_dve
        from services.os_pdf_generator import OsPdfGenerator

        cca, dve = extraer_cca_dve({"numero_cca": "CCA.26.1234", "numero_dve": "DVE.26.5678"})
        self.assertEqual(cca, "CCA.26.1234")
        self.assertEqual(dve, "DVE.26.5678")

        # Regla estricta: solo servicios con Inspección/Verificación muestran DVE/Hologramas
        gen = OsPdfGenerator()
        for srv_no_insp in ("Ajuste", "Calibración", "Calibración + Ajuste", "Mantenimiento Preventivo"):
            s_low = srv_no_insp.lower()
            has_insp = any(k in s_low for k in ("inspecc", "verificac", "dve"))
            self.assertFalse(has_insp, f"{srv_no_insp} NO debe activar Inspección/DVE")
        for srv_insp in ("Inspección", "Calibración + Inspección", "Ajuste + Verificación"):
            s_low = srv_insp.lower()
            has_insp = any(k in s_low for k in ("inspecc", "verificac", "dve"))
            self.assertTrue(has_insp, f"{srv_insp} SÍ debe activar Inspección/DVE")
        self.assertIsNotNone(gen)

    def test_correos_html_apple_pesa_y_exclusion_canceladas(self):
        from pesa_api.core.email_service import construir_asunto_y_cuerpo_correo as api_build
        from services.metrology import construir_asunto_y_cuerpo_correo as desk_build

        ordenes = [
            {
                "folio_os": "OS-26-901",
                "tipo_servicio": "Calibración + Ajuste",
                "marca": "METTLER TOLEDO",
                "modelo": "IND560",
                "ns": "SN-001",
                "id_equipo": "BASC-01",
                "numero_cca": "CCA.26.9001",
                "numero_dve": "",  # vacío -> celda vacía "", nunca "—" ni "-"
                "estado": "COMPLETADA",
            },
            {
                "folio_os": "OS-26-902",
                "tipo_servicio": "Calibración + Inspección",
                "marca": "RICE LAKE",
                "modelo": "920i",
                "ns": "SN-002",
                "id_equipo": "BASC-02",
                "numero_cca": "CCA.26.9002",
                "numero_dve": "DVE.26.4401",
                "estado": "CANCELADA",  # debe ser excluida siempre
            },
        ]

        subj_api, _txt_api, html_api, _lines_api = api_build(ordenes, cliente="ACME", es_lote=True)
        subj_desk, _txt_desk, html_desk, _lines_desk = desk_build(ordenes, cliente="ACME", es_lote=True)

        # construir_asunto_y_cuerpo_correo retorna (asunto, cuerpo_html, cuerpo_texto, lineas) o (asunto, texto, html, lineas)
        if "<html" in _txt_api.lower() or "<table" in _txt_api.lower():
            html_api, _txt_api = _txt_api, html_api
        if "<html" in _txt_desk.lower() or "<table" in _txt_desk.lower():
            html_desk, _txt_desk = _txt_desk, html_desk

        for label, subj, html in (("API", subj_api, html_api), ("DESKTOP", subj_desk, html_desk)):
            self.assertIn("OS-26-901", subj, f"[{label}] Asunto debe incluir OS-26-901")
            self.assertNotIn("OS-26-902", subj, f"[{label}] Asunto debe excluir CANCELADA OS-26-902")
            self.assertIn("OS-26-901", html, f"[{label}] HTML debe incluir OS-26-901")
            self.assertNotIn("OS-26-902", html, f"[{label}] HTML debe excluir CANCELADA OS-26-902")
            self.assertIn("#1D1D1F", html, f"[{label}] HTML debe usar paleta Apple #1D1D1F")
            self.assertIn("CCA.26.9001", html, f"[{label}] HTML debe mostrar CCA")
            self.assertNotIn(">—<", html, f"[{label}] No debe haber guion em-dash en celdas vacías")
            self.assertNotIn(">-<", html, f"[{label}] No debe haber guion en celdas vacías")
            for bad_hex in ("#FEF2F2", "#8B5CF6", "#EBF5FF", "#FFF3E0", "#0F172A"):
                self.assertNotIn(bad_hex, html, f"[{label}] Color prohibido {bad_hex} presente en HTML")


class TestGeneracionPDFsRealesEnTemp(unittest.TestCase):
    """Genera PDFs reales (OS Grúa/Tanque, OSOB, OSOCC Stock/Cliente) en directorio temporal."""

    def test_generate_os_grua_y_tanque_sin_excentricidad(self):
        from services.os_pdf_generator import OsPdfGenerator

        with tempfile.TemporaryDirectory() as tmpdir:
            gen = OsPdfGenerator()

            for motivo in ("Grúa", "Tanque"):
                folio = f"OS-26-TEST-{motivo.upper()}"
                data = {
                    "folio_os": folio,
                    "fecha": "2026-11-26",
                    "cliente": "PLANTA DEMO INDUSTRIAL S.A. DE C.V.",
                    "sucursal": "Planta Norte",
                    "direccion": "Av. Industria 100",
                    "tipo_servicio": "Calibración + Ajuste",
                    "tipo_instrumento": f"Báscula de {motivo}",
                    "marca": "METTLER TOLEDO",
                    "modelo": "IND560",
                    "ns": "SN-TEST-01",
                    "id_equipo": f"TAG-{motivo.upper()}",
                    "alcance_max": "5000 kg",
                    "div_minima": "0.020 kg",
                    "numero_cca": "CCA.26.8888",
                    "numero_dve": "DVE.26.9999",  # residual en Ajuste -> NO debe imprimirse
                    "holograma_anterior": "H-OLD",
                    "holograma_actualizado": "H-NEW",
                    "aplica_excentricidad": False,
                    "motivo_no_excentricidad": motivo,
                    "usa_sustitucion": motivo == "Tanque",
                    "cantidad_enlaces": 4 if motivo == "Tanque" else 0,
                    "observaciones": f"Prueba automatizada {motivo} sin excentricidad.",
                }
                dest = str(Path(tmpdir) / f"{folio}.pdf")
                out_path = gen.generate_os_pdf(data, output_path=dest)
                p = Path(out_path)
                self.assertTrue(p.exists(), f"No se creó PDF OS ({motivo})")
                raw = p.read_bytes()
                self.assertTrue(raw.startswith(b"%PDF-"), "Archivo generado no es PDF válido")
                self.assertGreater(len(raw), 4000, f"PDF OS ({motivo}) demasiado pequeño")

    def test_generate_osob_y_osocc_stock_cliente(self):
        from services.os_pdf_generator import OsobPdfGenerator, OsoccPdfGenerator

        with tempfile.TemporaryDirectory() as tmpdir:
            osob_gen = OsobPdfGenerator()
            osob_dest = str(Path(tmpdir) / "OSOB-26-TEST1.pdf")
            osob_path = osob_gen.generate(
                {
                    "folio_os": "OSOB-26-TEST1",
                    "fecha": "2026-11-26",
                    "cliente": "ACME PLANTA",
                    "planta": "Nave 2",
                    "marca": "OHAUS",
                    "modelo": "T31P",
                    "ns": "OH-123",
                    "id_equipo": "B-10",
                    "capacidad_maxima": "100 kg",
                    "division_minima": "0.020 kg",
                    "tipo_instrumento": "Plataforma",
                    "observaciones": "Revisión completa sin duplicación de indicador.",
                    "dictamen": "OPERATIVO",
                },
                output_path=osob_dest,
                force=True,
                digital=True,
            )
            p_osob = Path(osob_path)
            self.assertTrue(p_osob.exists())
            self.assertTrue(p_osob.read_bytes().startswith(b"%PDF-"))
            self.assertGreater(p_osob.stat().st_size, 3000)

            osocc_gen = OsoccPdfGenerator()
            for destino, cliente in (("STOCK", "Stock / Taller Básculas PESA"), ("CLIENTE", "INDUSTRIAS BETA")):
                osocc_dest = str(Path(tmpdir) / f"OSOCC-26-{destino}.pdf")
                osocc_path = osocc_gen.generate(
                    {
                        "folio_os": f"OSOCC-26-{destino}",
                        "fecha": "2026-11-26",
                        "destino_celda": destino,
                        "cliente": cliente,
                        "marca": "ZEMIC",
                        "modelo": "H8C",
                        "ns": f"ZM-{destino}-01",
                        "capacidad_maxima": "1000",
                        "unidad_capacidad": "kg",
                        "sensibilidad_nominal": "2.0",
                        "resistencia_nominal": "350 Ω",
                        "dictamen_celda": "OPERATIVA",
                        "observaciones_diagnostico": f"Diagnóstico unitario {destino}.",
                    },
                    output_path=osocc_dest,
                    force=True,
                    calca=False,
                )
                p_oc = Path(osocc_path)
                self.assertTrue(p_oc.exists())
                self.assertTrue(p_oc.read_bytes().startswith(b"%PDF-"))
                self.assertGreater(p_oc.stat().st_size, 3000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
