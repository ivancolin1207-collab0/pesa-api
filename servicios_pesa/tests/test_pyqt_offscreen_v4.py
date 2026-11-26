# -*- coding: utf-8 -*-
"""
test_pyqt_offscreen_v4.py — Pruebas PyQt6 Offscreen (QT_QPA_PLATFORM=offscreen)
Verifica instanciación sin excepciones (0 errores QPainter/QSS) y ausencia de
recorte de altura (height() >= sizeHint().height()) en tarjetas clave.
"""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

WORKSPACE_ROOT = Path(__file__).resolve().parents[2]
SERVICIOS_DIR = WORKSPACE_ROOT / "servicios_pesa"
for _p in (str(WORKSPACE_ROOT), str(SERVICIOS_DIR)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from PyQt6.QtCore import QThread
from PyQt6.QtWidgets import QApplication

_APP = QApplication.instance() or QApplication(sys.argv)


def _stop_child_threads(widget) -> None:
    """Detiene limpiamente hilos QThread hijos antes de destruir el widget en pruebas offscreen."""
    for th in widget.findChildren(QThread):
        if th.isRunning():
            th.requestInterruption()
            th.quit()
            if not th.wait(1500):
                th.terminate()
                th.wait(500)


class TestPyQtOffscreenV4(unittest.TestCase):
    """Instancia vistas y diálogos corporativos PyQt6 v4.0 en modo offscreen."""

    def test_theme_qss_loads_cleanly_with_valid_icons(self):
        from ui.styles.theme import STYLESHEET, COLORS
        from ui.theme import PALETTE, StatusBadge, LinearProgressBar, SectionCard, PrimaryButton, SecondaryButton

        self.assertNotIn("!important", STYLESHEET)
        self.assertNotIn("chevron_down.png", STYLESHEET)
        self.assertIn("#F5F5F7", STYLESHEET)
        self.assertIn("#C8102E", STYLESHEET)
        self.assertEqual(COLORS["accent_primary"], "#C8102E")
        self.assertEqual(PALETTE["brand"], "#C8102E")

        _APP.setStyleSheet(STYLESHEET)

        # Renderizar StatusBadge y LinearProgressBar (verifica seguridad QPainter float/QRectF)
        badge = StatusBadge("Cerrado", PALETTE["dot_green"])
        badge.show()
        badge.repaint()
        self.assertGreaterEqual(badge.width(), 44)
        self.assertEqual(badge.height(), 24)
        badge.close()

        bar = LinearProgressBar()
        bar.set_running(True)
        bar.resize(300, 3)
        bar.show()
        bar.repaint()
        bar.set_running(False)
        bar.close()

        card = SectionCard()
        btn_p = PrimaryButton("Guardar")
        btn_s = SecondaryButton("Cancelar")
        card.content_layout.addWidget(btn_p)
        card.content_layout.addWidget(btn_s)
        card.show()
        _APP.processEvents()
        card.close()

    def test_batch_generator_cards_no_clipping(self):
        from ui.widgets.batch_generator_widget import BatchGeneratorWidget, SelectCard

        w = BatchGeneratorWidget()
        w.resize(1280, 900)
        w.show()
        _APP.processEvents()
        _APP.processEvents()

        cards = w.findChildren(SelectCard)
        self.assertGreaterEqual(len(cards), 9, "Deben existir tarjetas de modalidad y tipo de documento")
        for c in cards:
            if c.isVisible():
                sh = c.sizeHint()
                self.assertGreaterEqual(
                    c.height(),
                    sh.height(),
                    f"SelectCard recortada: height={c.height()} < sizeHint={sh.height()}",
                )
        _stop_child_threads(w)
        w.close()

    def test_modo_formato_dialog_cards_no_clipping(self):
        from ui.dialogs.modo_formato_dialog import ModoFormatoDialog

        dlg = ModoFormatoDialog(tipo_formato="OS")
        dlg.show()
        _APP.processEvents()
        for card in (dlg.card_fisico, dlg.card_digital):
            sh = card.sizeHint()
            self.assertGreaterEqual(
                card.height(),
                sh.height(),
                f"ModoFormatoDialog card recortada: height={card.height()} < sizeHint={sh.height()}",
            )
        dlg.close()

    def test_firma_widget_and_dialogs_instantiate_without_errors(self):
        from ui.widgets.firma_widget import FirmaWidget
        from ui.widgets.catalogos_widget import CatalogosWidget
        from ui.dialogs.osob_digital_dialog import OsobDigitalDialog
        from ui.dialogs.osocc_digital_dialog import OsoccDigitalDialog
        from ui.dialogs.login_dialog import LoginDialog

        fw = FirmaWidget()
        fw.resize(800, 600)
        fw.show()
        _APP.processEvents()
        _stop_child_threads(fw)
        fw.close()

        cat = CatalogosWidget()
        cat.resize(1100, 720)
        cat.show()
        _APP.processEvents()
        _stop_child_threads(cat)
        cat.close()

        osob = OsobDigitalDialog(os_id=0, folio="OSOB-26-OFFSCREEN", orden_data={"cliente": "ACME"})
        osob.show()
        _APP.processEvents()
        osob.close()

        osocc = OsoccDigitalDialog(os_id=0, folio="OSOCC-26-OFFSCREEN", orden_data={"cliente": "Stock"})
        osocc.show()
        _APP.processEvents()
        osocc.close()

        login = LoginDialog()
        login.show()
        _APP.processEvents()
        _stop_child_threads(login)
        login.close()

    def test_main_window_and_dashboard_instantiate_offscreen(self):
        from ui.main_window import MainWindow
        from ui.widgets.dashboard_widget import DashboardWidget

        dash = DashboardWidget()
        dash.resize(1200, 780)
        dash.show()
        _APP.processEvents()
        _stop_child_threads(dash)
        dash.close()

        mw = MainWindow()
        mw.resize(1366, 840)
        mw.show()
        _APP.processEvents()
        self.assertIsNotNone(mw)
        _stop_child_threads(mw)
        mw.close()


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestPyQtOffscreenV4)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    _APP.processEvents()
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(0 if result.wasSuccessful() else 1)
