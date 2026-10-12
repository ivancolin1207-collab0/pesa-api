import sys
path = r'D:\Ordenes De Servicio\servicios_pesa\ui\widgets\dashboard_widget.py'

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Edit 1: _COL_CLIENTE
old_cli = 'header.setSectionResizeMode(self._COL_CLIENTE,  QHeaderView.ResizeMode.Stretch)'
new_cli = 'header.setSectionResizeMode(self._COL_CLIENTE,  QHeaderView.ResizeMode.Fixed)\n        table.setColumnWidth(self._COL_CLIENTE, 220)'
content = content.replace(old_cli, new_cli)

# Edit 2: _COL_SUCURSAL
old_suc = 'header.setSectionResizeMode(self._COL_SUCURSAL, QHeaderView.ResizeMode.Stretch)'
new_suc = 'header.setSectionResizeMode(self._COL_SUCURSAL, QHeaderView.ResizeMode.Fixed)\n        table.setColumnWidth(self._COL_SUCURSAL, 260)'
content = content.replace(old_suc, new_suc)

# Edit 3: _SyncWorker
import re
pattern = re.compile(r'class _SyncWorker\(QThread\):.*?def run\(self\) -> None:\n        try:\n            if not _HAS_SYNC or _sync_manager is None:\n                self.finished_err\.emit\("SyncManager no disponible."\)\n                return\n            n = _sync_manager\.upload_pending\(\n                progress_callback=lambda cur, tot, f: self.progress\.emit\(cur, tot, f\)\n            \)\n            self.finished_ok\.emit\(n\)\n        except Exception as exc:\n            self.finished_err\.emit\(str\(exc\)\)', re.DOTALL)

new_sw = '''class _SyncWorker(QThread):
    """Worker que sube registros PENDING de SQLite a PostgreSQL en background."""

    progress     = pyqtSignal(int, int, str)
    finished_ok  = pyqtSignal(int)
    finished_err = pyqtSignal(str)
    started_sync = pyqtSignal(int)
    no_pending   = pyqtSignal()
    offline      = pyqtSignal()

    def run(self) -> None:
        try:
            if not _HAS_SYNC or _sync_manager is None:
                self.finished_err.emit("SyncManager no disponible.")
                return
            if not _sync_manager.is_online():
                self.offline.emit()
                return
            
            pending = _sync_manager.get_pending_count()
            if pending == 0:
                self.no_pending.emit()
                return

            self.started_sync.emit(pending)
            n = _sync_manager.upload_pending(
                progress_callback=lambda cur, tot, f: self.progress.emit(cur, tot, f)
            )
            self.finished_ok.emit(n)
        except Exception as exc:
            self.finished_err.emit(str(exc))'''

content = pattern.sub(new_sw, content)

# Edit 4: _on_sync_clicked
pattern_sync = re.compile(r'    def _on_sync_clicked\(self\) -> None:\n        if not _HAS_SYNC.*?self\._sync_worker\.start\(\)', re.DOTALL)

new_sync = '''    def _on_sync_clicked(self) -> None:
        if not _HAS_SYNC or _sync_manager is None:
            self._on_refresh_clicked()
            return

        self._btn_sync.setEnabled(False)
        self._btn_sync.setText("Conectando...")

        self._sync_worker = _SyncWorker()
        self._sync_worker.progress.connect(self._on_sync_progress)
        self._sync_worker.finished_ok.connect(self._on_sync_done)
        self._sync_worker.finished_err.connect(self._on_sync_error)
        self._sync_worker.started_sync.connect(self._on_started_sync)
        self._sync_worker.no_pending.connect(self._on_no_pending_sync)
        self._sync_worker.offline.connect(self._on_sync_offline)
        self._sync_worker.start()

    def _on_sync_offline(self) -> None:
        self._btn_sync.setEnabled(True)
        self._btn_sync.setText("Sincronizar todo")
        QMessageBox.warning(self, "Sin Conexion",
                            "No hay conexion al servidor.\\n"
                            "Conectate a la red de oficina e intenta de nuevo.")

    def _on_no_pending_sync(self) -> None:
        self._btn_sync.setEnabled(True)
        self._btn_sync.setText("Sincronizar todo")
        self._cache_valid = False
        self._data_cache.clear()
        self._refresh_pending_count()
        self._update_conn_badge()
        self._async_refresh(load_filters=False, force=True)
        QMessageBox.information(
            self, "Sincronización y Actualización",
            "No hay registros locales pendientes de sincronizar.\\n"
            "Se ha consultado y actualizado la lista de órdenes directamente desde PostgreSQL."
        )

    def _on_started_sync(self, pending: int) -> None:
        self._btn_sync.setText("Sincronizando...")
        self._progress_dlg = QProgressDialog(
            "Sincronizando registros con el servidor...", "Cancelar", 0, pending, self
        )
        self._progress_dlg.setWindowTitle("Sincronizacion")
        self._progress_dlg.setWindowModality(Qt.WindowModality.WindowModal)
        self._progress_dlg.setAutoClose(True)
        self._progress_dlg.show()'''

content = pattern_sync.sub(new_sync, content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("Done.")
