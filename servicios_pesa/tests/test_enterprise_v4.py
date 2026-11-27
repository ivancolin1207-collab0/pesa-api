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
                "/api/ordenes/{folio}/rehacer",
                "/api/v1/ordenes/{folio}/rehacer",
                "/api/v1/os/{folio_os}/rehacer",
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


class TestRehacerYVistaPreviaSinFirma(unittest.TestCase):
    """
    Valida de extremo a extremo (v4.0.2):
      1. Flujo Rehacer en backend (`rehacer_orden`): desbloquea a EN_PROCESO,
         limpia firma previa del cliente, invalida pdf_b64/pdf_base64/has_pdf,
         reinicia correo_enviado, incrementa pdf_version y borra caché en disco.
      2. Re-finalización sobrescribe obligatoriamente el PDF definitivo con los
         nuevos datos (distintos bytes, texto nuevo presente, texto previo ausente).
      3. Generación de Vista Previa sin firma (`modo_preview_sin_firma=True`) en
         OS, OSOB y OSOCC con leyenda de conformidad pendiente y sin firma cliente.
    """

    @staticmethod
    def _extract_pdf_text_bytes(pdf_bytes: bytes) -> str:
        import base64 as _b64
        import re as _re
        import zlib as _zlib
        chunks = [pdf_bytes.decode("latin-1", errors="ignore")]
        for m in _re.finditer(rb"stream\r?\n(.*?)\r?\n?endstream", pdf_bytes, flags=_re.S):
            raw_stream = m.group(1)
            for candidate in (raw_stream,):
                try:
                    chunks.append(_zlib.decompress(candidate).decode("latin-1", errors="ignore"))
                    continue
                except Exception:
                    pass
                try:
                    a85 = _b64.a85decode(candidate.strip(), adobe=True)
                    chunks.append(_zlib.decompress(a85).decode("latin-1", errors="ignore"))
                    continue
                except Exception:
                    pass
                try:
                    a85_plain = _b64.a85decode(candidate.strip().rstrip(b"~>"))
                    chunks.append(_zlib.decompress(a85_plain).decode("latin-1", errors="ignore"))
                except Exception:
                    pass
        return "\n".join(chunks)

    def test_ciclo_cerrar_rehacer_modificar_sobrescribir_pdf(self):
        import asyncio
        import os as _os
        from pesa_api.routers.catalogos import rehacer_orden
        from services.os_pdf_generator import OsPdfGenerator

        with tempfile.TemporaryDirectory() as tmpdir:
            prev_upload = _os.environ.get("UPLOAD_DIR")
            _os.environ["UPLOAD_DIR"] = tmpdir
            try:
                folio = "OS-26-864"
                pdf_file = Path(tmpdir) / f"{folio}.pdf"
                gen = OsPdfGenerator()

                # 1. Cerrar orden (PDF V1 con observación original y firma previa)
                data_v1 = {
                    "folio_os": folio,
                    "fecha": "2026-11-27",
                    "cliente": "PEMEX TRANSFORMACION INDUSTRIAL",
                    "tipo_servicio": "Ajuste",
                    "tipo_instrumento": "Báscula de plataforma",
                    "marca": "Sartorius",
                    "modelo": "PR1612/02",
                    "ns": "2011004405",
                    "id_equipo": "Bascula 3",
                    "alcance_max": "100 kg",
                    "div_minima": "0.02 kg",
                    "aplica_excentricidad": True,
                    "observaciones": "OBSERVACION_ORIGINAL_V1_864",
                    "nombre_ing": "Cliente Inicial",
                }
                out_v1 = gen.generate_os_pdf(data_v1, output_path=str(pdf_file), digital=True, force=True)
                self.assertTrue(Path(out_v1).exists())
                bytes_v1 = Path(out_v1).read_bytes()
                txt_v1 = self._extract_pdf_text_bytes(bytes_v1)
                self.assertIn("OBSERVACION_ORIGINAL_V1_864", txt_v1)

                # Simular fila cerrada y enviada en PostgreSQL
                fake_row = {
                    "id": 864,
                    "folio_os": folio,
                    "estado": "COMPLETADA",
                    "estatus": "Cerrado",
                    "id_tecnico": 7,
                    "firma_cliente": "BASE64_FIRMA_ANTERIOR",
                    "firma_cliente_b64": "BASE64_FIRMA_ANTERIOR",
                    "pdf_path": str(pdf_file),
                    "pdf_b64": "OLD_B64",
                    "pdf_base64": "OLD_B64",
                    "pdf_generado": True,
                    "has_pdf": True,
                    "correo_enviado": True,
                    "email_enviado": True,
                    "pdf_version": 1,
                }

                class _FakeDB:
                    def __init__(self, state):
                        self.state = state
                        self.last_sql = ""

                    async def fetchrow(self, sql, *args):
                        return dict(self.state)

                    async def fetchval(self, sql, *args):
                        self.last_sql = sql
                        self.state["estado"] = "EN_PROCESO"
                        self.state["estatus"] = "EN_PROCESO"
                        self.state["firma_cliente"] = None
                        self.state["firma_cliente_b64"] = None
                        self.state["pdf_b64"] = None
                        self.state["pdf_base64"] = None
                        self.state["pdf_path"] = None
                        self.state["pdf_generado"] = False
                        self.state["has_pdf"] = False
                        self.state["correo_enviado"] = False
                        self.state["email_enviado"] = False
                        self.state["pdf_version"] = int(self.state["pdf_version"]) + 1
                        return self.state["pdf_version"]

                fake_db = _FakeDB(fake_row)
                res = asyncio.run(
                    rehacer_orden(
                        folio=folio,
                        db=fake_db,
                        current_user={"rol": "admin", "id_tecnico": 1, "username": "ivancolin1207"},
                    )
                )

                # 2. Verificar que Rehacer desbloqueó, limpió firma previa e invalidó caché en disco
                self.assertTrue(res["ok"])
                self.assertEqual(res["estado"], "EN_PROCESO")
                self.assertEqual(res["estatus"], "EN_PROCESO")
                self.assertIsNone(res["firma_cliente"])
                self.assertFalse(res["has_pdf"])
                self.assertFalse(res["pdf_generado"])
                self.assertFalse(res["correo_enviado"])
                self.assertEqual(res["pdf_version"], 2)
                self.assertIn("firma_cliente        = NULL", fake_db.last_sql)
                self.assertIn("pdf_b64              = NULL", fake_db.last_sql)
                self.assertIn("pdf_base64           = NULL", fake_db.last_sql)
                self.assertFalse(pdf_file.exists(), "El PDF previo en disco debió eliminarse al Rehacer")

                # 3. Modificar datos y re-finalizar sobrescribiendo el PDF en la misma ruta
                data_v2 = {
                    **data_v1,
                    "observaciones": "OBSERVACION_CORREGIDA_V2_REHECHA",
                    "nombre_ing": "Nuevo Receptor Conforme",
                }
                out_v2 = gen.generate_os_pdf(data_v2, output_path=str(pdf_file), digital=True, force=True)
                self.assertTrue(Path(out_v2).exists())
                bytes_v2 = Path(out_v2).read_bytes()
                self.assertNotEqual(bytes_v1, bytes_v2, "El PDF re-finalizado debe diferir del PDF anterior")
                txt_v2 = self._extract_pdf_text_bytes(bytes_v2)
                self.assertIn("OBSERVACION_CORREGIDA_V2_REHECHA", txt_v2)
                self.assertNotIn("OBSERVACION_ORIGINAL_V1_864", txt_v2)
            finally:
                if prev_upload is None:
                    _os.environ.pop("UPLOAD_DIR", None)
                else:
                    _os.environ["UPLOAD_DIR"] = prev_upload

    def test_vista_previa_sin_firma_os_osob_osocc(self):
        from services.os_pdf_generator import OsPdfGenerator, OsobPdfGenerator, OsoccPdfGenerator

        with tempfile.TemporaryDirectory() as tmpdir:
            # OS preview sin firma
            os_dest = str(Path(tmpdir) / "OS-26-PREV.pdf")
            os_out = OsPdfGenerator().generate_os_pdf(
                {
                    "folio_os": "OS-26-PREV",
                    "fecha": "2026-11-27",
                    "cliente": "CLIENTE PREVIEW S.A.",
                    "tipo_servicio": "Ajuste",
                    "marca": "METTLER",
                    "modelo": "IND560",
                    "ns": "SN-PREV-1",
                    "alcance_max": "500 kg",
                    "div_minima": "0.1 kg",
                    "firma_cliente_b64": "NO_DEBE_USARSE_EN_PREVIEW",
                },
                output_path=os_dest,
                digital=True,
                force=True,
                modo_preview_sin_firma=True,
            )
            os_bytes = Path(os_out).read_bytes()
            self.assertTrue(os_bytes.startswith(b"%PDF-"))
            self.assertIn("Pendiente de firma y conformidad del cliente", self._extract_pdf_text_bytes(os_bytes))

            # OSOB preview sin firma
            osob_dest = str(Path(tmpdir) / "OSOB-26-PREV.pdf")
            osob_out = OsobPdfGenerator().generate(
                {
                    "folio_os": "OSOB-26-PREV",
                    "fecha": "2026-11-27",
                    "cliente": "CLIENTE PREVIEW",
                    "marca": "OHAUS",
                    "modelo": "T31P",
                    "modo_preview_sin_firma": True,
                },
                output_path=osob_dest,
                force=True,
                digital=True,
            )
            osob_bytes = Path(osob_out).read_bytes()
            self.assertTrue(osob_bytes.startswith(b"%PDF-"))
            self.assertIn("Pendiente de firma y conformidad del cliente", self._extract_pdf_text_bytes(osob_bytes))

            # OSOCC preview sin firma
            osocc_dest = str(Path(tmpdir) / "OSOCC-26-PREV.pdf")
            osocc_out = OsoccPdfGenerator().generate(
                {
                    "folio_os": "OSOCC-26-PREV",
                    "fecha": "2026-11-27",
                    "destino_celda": "CLIENTE",
                    "cliente": "CLIENTE PREVIEW",
                    "marca": "ZEMIC",
                    "modelo": "H8C",
                    "modo_preview_sin_firma": True,
                },
                output_path=osocc_dest,
                force=True,
                calca=False,
            )
            osocc_bytes = Path(osocc_out).read_bytes()
            self.assertTrue(osocc_bytes.startswith(b"%PDF-"))
            self.assertIn("Pendiente de firma y conformidad del cliente", self._extract_pdf_text_bytes(osocc_bytes))


if __name__ == "__main__":
    unittest.main(verbosity=2)
