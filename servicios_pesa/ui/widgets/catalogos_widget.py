"""
Widget de cat\u00e1logos \u2014 CRUD para: Clientes, T\u00e9cnicos,
Tipos de Servicio y Tipos de Instrumento.

Incluye gesti\u00f3n de roles RBAC (Administrador, Log\u00edstica, Recepci\u00f3n,
T\u00e9cnico, T\u00e9cnico Calibrador, T\u00e9cnico Inspector) y asignaci\u00f3n /
restablecimiento de contrase\u00f1a por parte del Administrador.
"""
import logging
import unicodedata
import re
from typing import Optional

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QTableWidget, QTableWidgetItem, QHeaderView, QTabWidget,
    QLineEdit, QFormLayout, QDialog, QDialogButtonBox,
    QMessageBox, QAbstractItemView, QComboBox, QApplication,
    QGroupBox, QCheckBox, QScrollArea, QFrame, QSizePolicy,
)
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QColor

logger = logging.getLogger(__name__)

# \u2500\u2500 Paleta de badges por rol \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500
_ROL_BADGE = {
    "Administrador":      ("#6C3483", "#EAD6F1"),
    "Log\u00edstica":          ("#1A5276", "#D6EAF8"),
    "Recepci\u00f3n":          ("#117A65", "#D1F2EB"),
    "T\u00e9cnico":            ("#784212", "#FAE5D3"),
    "T\u00e9cnico Calibrador": ("#922B21", "#FADBD8"),
    "T\u00e9cnico Inspector":  ("#1B4F72", "#D6EAF8"),
}


# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550
# Di\u00e1logo especializado Tecnico / Usuario (con Rol + Contrase\u00f1a)
# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550
class _TecnicoEditDialog(QDialog):
    """
    Di\u00e1logo de alta / edici\u00f3n de T\u00e9cnico.
    Campos: Nombre Completo, Usuario, Rol, Contrase\u00f1a (toggle), Tel\u00e9fono, Email.
    - Alta (is_new=True):    contrase\u00f1a obligatoria.
    - Edici\u00f3n (is_new=False): contrase\u00f1a opcional (vac\u00edo = conservar actual).
    """

    def __init__(self, is_new: bool = True, data: dict = None, parent=None):
        super().__init__(parent)
        self._is_new = is_new
        self._data   = data or {}
        title = "Nuevo T\u00e9cnico / Usuario" if is_new else "Editar T\u00e9cnico / Usuario"
        self.setWindowTitle(title)
        self.setMinimumWidth(460)
        self.setModal(True)
        self._usuario_manually_edited = False

        try:
            from models.catalogo import ROLES_PESA
            roles = ROLES_PESA
        except ImportError:
            roles = [
                "Administrador", "Logística", "Recepción",
                "Técnico", "Técnico Calibrador", "Técnico Inspector",
            ]

        # Detectar roles ya asignados — soporta: list de Python, JSON string,
        # cadena separada por comas, o rol singular del campo 'rol'.
        import json as _json

        def _parse_roles(raw) -> set:
            if raw is None:
                return set()
            # Ya viene como lista Python (psycopg2 json column o TEXT[])
            if isinstance(raw, (list, tuple)):
                return {str(x).strip() for x in raw if x}
            if isinstance(raw, str):
                s = raw.strip()
                if not s:
                    return set()
                # Intentar parsear JSON array: ["Técnico", "Técnico Inspector"]
                if s.startswith("["):
                    try:
                        parsed = _json.loads(s)
                        return {str(x).strip() for x in parsed if x}
                    except Exception:
                        pass
                # Intentar parsear PostgreSQL array literal: {Técnico,"Técnico Inspector"}
                if s.startswith("{"):
                    inner = s.strip("{}").strip()
                    parts = [p.strip().strip('"') for p in inner.split(",") if p.strip()]
                    return {p for p in parts if p}
                # Cadena separada por comas
                if "," in s:
                    return {p.strip() for p in s.split(",") if p.strip()}
                # Rol único
                return {s}
            return {str(raw)}

        existing_roles_raw = self._data.get("roles")
        existing_roles = _parse_roles(existing_roles_raw)
        # Si no se pudo obtener ningún rol de 'roles', caer al campo 'rol'
        if not existing_roles:
            existing_roles = _parse_roles(self._data.get("rol") or "Técnico")

        root = QVBoxLayout(self)
        root.setSpacing(14)
        root.setContentsMargins(20, 20, 20, 20)

        form = QFormLayout()
        form.setSpacing(10)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignRight)

        # ──────────────── Nombre Completo ──────────────────────────────────────────────────────────────────────────
        self._inp_nombre = QLineEdit()
        self._inp_nombre.setPlaceholderText("Ej: Luis Fernando Guerrero Arroyo")
        self._inp_nombre.setFixedHeight(36)
        if self._data.get("nombre_completo"):
            self._inp_nombre.setText(str(self._data["nombre_completo"]))
        self._inp_nombre.textChanged.connect(self._auto_generate_username)
        form.addRow("Nombre Completo *:", self._inp_nombre)

        # ──────────────── Usuario ──────────────────────────────────────────────────────────────────────────────────
        self._inp_usuario = QLineEdit()
        self._inp_usuario.setPlaceholderText("Ej: luis.guerrero")
        self._inp_usuario.setFixedHeight(36)
        if self._data.get("usuario"):
            self._inp_usuario.setText(str(self._data["usuario"]))
        self._inp_usuario.textEdited.connect(
            lambda: setattr(self, "_usuario_manually_edited", True)
        )
        form.addRow("Usuario (login) *:", self._inp_usuario)

        # ──────────────── Perfiles / Roles (multi-selección) ────────────────────────────────────
        roles_group = QGroupBox("Perfiles / Roles")
        roles_group.setStyleSheet(
            "QGroupBox { font-weight:600; font-size:12px; border:1px solid #CBD5E1;"
            " border-radius:6px; margin-top:6px; padding:10px 8px; }"
            "QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 4px; color:#374151; }"
        )
        roles_vlay = QVBoxLayout(roles_group)
        roles_vlay.setSpacing(6)
        roles_vlay.setContentsMargins(8, 10, 8, 8)

        self._checks: dict[str, QCheckBox] = {}
        for rol_name in roles:
            chk = QCheckBox(rol_name)
            chk.setChecked(rol_name in existing_roles)
            chk.setStyleSheet("font-size:12px; padding: 2px 4px;")
            self._checks[rol_name] = chk
            roles_vlay.addWidget(chk)

        note_roles = QLabel("ℹ️ Un usuario puede tener múltiples perfiles activos.")
        note_roles.setStyleSheet("color:#6B7280; font-size:10px; padding-left:4px;")
        roles_vlay.addWidget(note_roles)
        form.addRow("", roles_group)

        # ──────────────── Contraseña con toggle ────────────────────────────────────────────────────────────────────
        pwd_row = QHBoxLayout()
        self._inp_pwd = QLineEdit()
        self._inp_pwd.setEchoMode(QLineEdit.EchoMode.Password)
        self._inp_pwd.setFixedHeight(36)
        if is_new:
            self._inp_pwd.setPlaceholderText("Contraseña (obligatoria para nuevos usuarios)")
        else:
            self._inp_pwd.setPlaceholderText("Dejar en blanco para conservar la contraseña actual")
        pwd_row.addWidget(self._inp_pwd, stretch=1)

        self._btn_eye = QPushButton("\U0001f441")
        self._btn_eye.setFixedSize(36, 36)
        self._btn_eye.setCheckable(True)
        self._btn_eye.setToolTip("Mostrar / ocultar contraseña")
        self._btn_eye.toggled.connect(self._toggle_pwd)
        pwd_row.addWidget(self._btn_eye)
        form.addRow("Contraseña:", pwd_row)

        # ──────────────── Teléfono y Email ─────────────────────────────────────────────────────────────────────────
        self._inp_telefono = QLineEdit()
        self._inp_telefono.setPlaceholderText("Número de contacto (opcional)")
        self._inp_telefono.setFixedHeight(36)
        if self._data.get("telefono"):
            self._inp_telefono.setText(str(self._data["telefono"]))
        form.addRow("Teléfono:", self._inp_telefono)

        self._inp_email = QLineEdit()
        self._inp_email.setPlaceholderText("correo@empresa.com (opcional)")
        self._inp_email.setFixedHeight(36)
        if self._data.get("email"):
            self._inp_email.setText(str(self._data["email"]))
        form.addRow("Email:", self._inp_email)

        root.addLayout(form)

        if not is_new:
            note = QLabel("ℹ️  Si dejas la contraseña en blanco, se conserva la actual.")
            note.setStyleSheet(
                "background:#F0F9FF; color:#1A5276; border:1px solid #AED6F1;"
                " border-radius:6px; padding:6px 10px; font-size:11px;"
            )
            root.addWidget(note)

        # ──────────────── Botones ──────────────────────────────────────────────────────────────────────────────────
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        ok_btn = buttons.button(QDialogButtonBox.StandardButton.Ok)
        if ok_btn:
            ok_btn.setText("Guardar")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    # ──────────────── Helpers ──────────────────────────────────────────────────────────────────────────────────
    def _toggle_pwd(self, show: bool) -> None:
        mode = QLineEdit.EchoMode.Normal if show else QLineEdit.EchoMode.Password
        self._inp_pwd.setEchoMode(mode)
        self._btn_eye.setText("\U0001f648" if show else "\U0001f441")

    def _auto_generate_username(self, text: str) -> None:
        if self._usuario_manually_edited:
            return
        clean = unicodedata.normalize("NFD", text).encode("ascii", "ignore").decode("utf-8").lower()
        parts = [p for p in clean.split() if p]
        if not parts:
            self._inp_usuario.setText("")
            return
        if len(parts) >= 3:
            nombre, apellido = parts[0], parts[-2]
        elif len(parts) == 2:
            nombre, apellido = parts[0], parts[1]
        else:
            nombre = apellido = parts[0]
        username = re.sub(r"[^a-z0-9.]", "", f"{nombre}.{apellido}")
        self._inp_usuario.blockSignals(True)
        self._inp_usuario.setText(username)
        self._inp_usuario.blockSignals(False)

    def _validate_and_accept(self) -> None:
        nombre  = self._inp_nombre.text().strip()
        usuario = self._inp_usuario.text().strip()
        pwd     = self._inp_pwd.text()
        if not nombre:
            QMessageBox.warning(self, "Campo requerido", "El Nombre Completo es obligatorio.")
            self._inp_nombre.setFocus()
            return
        if not usuario:
            QMessageBox.warning(self, "Campo requerido", "El Usuario (login) es obligatorio.")
            self._inp_usuario.setFocus()
            return
        if self._is_new and not pwd:
            QMessageBox.warning(
                self, "Contraseña requerida",
                "Debes ingresar una contraseña para el nuevo usuario."
            )
            self._inp_pwd.setFocus()
            return
        # Validar que al menos un perfil esté seleccionado
        selected = [name for name, chk in self._checks.items() if chk.isChecked()]
        if not selected:
            QMessageBox.warning(
                self, "Perfil requerido",
                "Debes seleccionar al menos un perfil / rol para el usuario."
            )
            return
        self.accept()

    def get_data(self) -> dict:
        import json as _json
        selected_roles = [name for name, chk in self._checks.items() if chk.isChecked()]
        primary_rol    = selected_roles[0] if selected_roles else "Técnico"
        return {
            "nombre_completo": self._inp_nombre.text().strip() or None,
            "usuario":         self._inp_usuario.text().strip() or None,
            "rol":             primary_rol,                          # backward compat
            "roles":           _json.dumps(selected_roles),          # nueva columna JSON
            "roles_list":      selected_roles,                       # para la UI
            "password":        self._inp_pwd.text() or None,
            "telefono":        self._inp_telefono.text().strip() or None,
            "email":           self._inp_email.text().strip() or None,
        }


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Diálogo genérico (Clientes, TipoServicio, TipoInstrumento)
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class _EditDialog(QDialog):
    """Diálogo genérico para crear/editar un registro de catálogo simple."""

    def __init__(self, title: str, fields: list[tuple[str, str, str]], data: dict = None, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(420)
        self._fields: dict[str, QLineEdit] = {}
        layout = QVBoxLayout(self)
        form   = QFormLayout()
        form.setSpacing(10)
        for label, key, placeholder in fields:
            le = QLineEdit()
            le.setPlaceholderText(placeholder)
            if data and key in data and data[key]:
                le.setText(str(data[key]))
            # Al modificar texto, remover cualquier borde rojo de validación
            le.textChanged.connect(lambda _, inp=le: inp.setStyleSheet(""))
            form.addRow(f"{label}:", le)
            self._fields[key] = le
        layout.addLayout(form)
        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _validate_and_accept(self) -> None:
        """
        Valida que el campo 'Nombre' no esté vacío.
        El campo 'Descripción' es totalmente OPCIONAL y NUNCA bloquea con borde rojo.
        """
        nombre_le = self._fields.get("nombre")
        if nombre_le is not None:
            val = nombre_le.text().strip()
            if not val:
                nombre_le.setStyleSheet("border: 1.5px solid #FF3B30; border-radius: 4px; background: #FFF5F5;")
                nombre_le.setFocus()
                QMessageBox.warning(self, "Campo requerido", "El campo 'Nombre' es obligatorio.")
                return
            else:
                nombre_le.setStyleSheet("")

        # El campo 'descripcion' es opcional, no requiere validación.
        self.accept()

    def get_data(self) -> dict:
        d = {}
        for key, le in self._fields.items():
            val = le.text().strip()
            d[key] = val if val else None

        # Si descripción viene vacía, asignar el mismo nombre para consistencia
        if "descripcion" in self._fields and not d.get("descripcion"):
            d["descripcion"] = d.get("nombre") or ""

        return d


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
def _broadcast_catalogs_update() -> None:
    """Refresca todos los widgets con _load_catalogs o _load_catalogos en la aplicación."""
    for widget in QApplication.topLevelWidgets():
        for fn_name in ("_load_catalogs", "_load_catalogos", "load_catalogo_tipos_instrumento"):
            if hasattr(widget, fn_name) and callable(getattr(widget, fn_name)):
                try:
                    getattr(widget, fn_name)()
                except Exception as exc:
                    logger.debug("Error al llamar %s: %s", fn_name, exc)
        for child in widget.findChildren(QWidget):
            for fn_name in ("_load_catalogs", "_load_catalogos", "load_catalogo_tipos_instrumento"):
                if hasattr(child, fn_name) and callable(getattr(child, fn_name)):
                    try:
                        getattr(child, fn_name)()
                    except Exception as exc:
                        logger.debug("Error al llamar %s en child: %s", fn_name, exc)


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class _CatalogTab(QWidget):
    """Tab genérico de CRUD para un catálogo."""

    FIELDS: list[tuple[str, str, str]] = []
    TITLE: str = "Catálogo"
    COLUMNS: list[str] = ["ID", "Nombre"]

    def __init__(self, repo, parent=None):
        super().__init__(parent)
        self._repo = repo
        self._setup_ui()
        self._load()

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(10)

        toolbar = QHBoxLayout()
        btn_new = QPushButton("➕  Nuevo")
        btn_new.setProperty("class", "primary")
        btn_new.setFixedWidth(110)
        btn_new.clicked.connect(self._new_record)
        toolbar.addWidget(btn_new)

        btn_edit = QPushButton("✏️  Editar")
        btn_edit.setFixedWidth(110)
        btn_edit.clicked.connect(self._edit_record)
        toolbar.addWidget(btn_edit)

        btn_del = QPushButton("✖️  Desactivar")
        btn_del.setProperty("class", "danger")
        btn_del.setFixedWidth(130)
        btn_del.clicked.connect(self._delete_record)
        toolbar.addWidget(btn_del)

        toolbar.addStretch()

        btn_refresh = QPushButton("↻  Actualizar")
        btn_refresh.setFixedWidth(120)
        btn_refresh.clicked.connect(self._load)
        toolbar.addWidget(btn_refresh)

        root.addLayout(toolbar)

        self._table = QTableWidget(0, len(self.COLUMNS))
        self._table.setHorizontalHeaderLabels(self.COLUMNS)
        self._table.verticalHeader().setVisible(False)
        self._table.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._table.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._table.setAlternatingRowColors(True)
        self._table.doubleClicked.connect(self._edit_record)
        hdr = self._table.horizontalHeader()
        hdr.setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        root.addWidget(self._table)

        self._rows: list[dict] = []

    def _load(self) -> None:
        try:
            self._rows = self._repo.get_all()
        except Exception as exc:
            logger.error("Error al cargar catálogo: %s", exc)
            self._rows = []
        self._populate()

    def _populate(self) -> None:
        self._table.setRowCount(0)
        for row_data in self._rows:
            i = self._table.rowCount()
            self._table.insertRow(i)
            self._table.setRowHeight(i, 34)
            for col_idx, col_val in enumerate(self._get_row_values(row_data)):
                item = QTableWidgetItem(str(col_val) if col_val else "")
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col_idx == 0:
                    item.setData(Qt.ItemDataRole.UserRole, row_data.get("id"))
                    item.setForeground(Qt.GlobalColor.gray)
                self._table.setItem(i, col_idx, item)

    def _get_row_values(self, row_data: dict) -> list:
        return [row_data.get("id"), row_data.get("nombre")]

    def _get_selected_id(self) -> Optional[int]:
        row = self._table.currentRow()
        if row < 0:
            return None
        item = self._table.item(row, 0)
        return item.data(Qt.ItemDataRole.UserRole) if item else None

    def _get_selected_data(self) -> Optional[dict]:
        item_id = self._get_selected_id()
        if item_id is None:
            return None
        return next((r for r in self._rows if r.get("id") == item_id), None)

    def _new_record(self) -> None:
        dlg = _EditDialog(f"Nuevo — {self.TITLE}", self.FIELDS, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            try:
                self._repo.create(data)
                self._load()
                _broadcast_catalogs_update()
            except Exception as exc:
                logger.error("Error al crear registro en %s: %s", self.TITLE, exc, exc_info=True)
                err_str = str(exc)
                if "unique" in err_str.lower() or "duplicad" in err_str.lower() or "uq_" in err_str.lower():
                    detalles = f"Ya existe un registro con el nombre '{data.get('nombre')}'.\nPor favor usa un nombre distinto."
                else:
                    detalles = f"No se pudo guardar el registro en la base de datos:\n{exc}"
                QMessageBox.critical(self, "Error al Guardar", detalles)

    def _edit_record(self) -> None:
        data = self._get_selected_data()
        if not data:
            return
        dlg = _EditDialog(f"Editar — {self.TITLE}", self.FIELDS, data=data, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            new_data = dlg.get_data()
            try:
                self._repo.update(data["id"], new_data)
                self._load()
                _broadcast_catalogs_update()
            except Exception as exc:
                logger.error("Error al actualizar registro en %s: %s", self.TITLE, exc, exc_info=True)
                err_str = str(exc)
                if "unique" in err_str.lower() or "duplicad" in err_str.lower() or "uq_" in err_str.lower():
                    detalles = f"Ya existe un registro con el nombre '{new_data.get('nombre')}'.\nPor favor usa un nombre distinto."
                else:
                    detalles = f"No se pudo actualizar el registro en la base de datos:\n{exc}"
                QMessageBox.critical(self, "Error al Actualizar", detalles)

    def _delete_record(self) -> None:
        item_id = self._get_selected_id()
        if not item_id:
            return
        reply = QMessageBox.question(
            self, "Confirmar",
            "¿Desactivar este registro? Permanecerá en registros históricos.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply == QMessageBox.StandardButton.Yes:
            try:
                self._repo.delete(item_id)
                self._load()
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo desactivar:\n{exc}")


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Diálogos de Fusión de Duplicados
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class _FusionClientesDialog(QDialog):
    """
    Modal para fusionar clientes duplicados.
    El usuario selecciona cuáles son duplicados y cuál es el canónico.
    """

    def __init__(self, clientes: list[dict], parent=None):
        super().__init__(parent)
        self.setWindowTitle("🔗  Fusionar Clientes Duplicados")
        self.setMinimumSize(640, 500)
        self.setModal(True)
        self._clientes = clientes
        self._canonico_id: int | None = None
        self._dup_ids: list[int] = []
        self._setup_ui()

    def _setup_ui(self):
        root = QVBoxLayout(self)
        root.setSpacing(12)
        root.setContentsMargins(20, 20, 20, 20)

        # Instrucciones
        lbl_inst = QLabel(
            "1. Marca las casillas de todos los <b>duplicados</b> (incluyendo el principal).<br>"
            "2. Elige el <b>Registro Principal</b> (canónico) en el combo de abajo.<br>"
            "3. Haz clic en <b>Fusionar</b>. Los duplicados se fusionarán en el principal."
        )
        lbl_inst.setWordWrap(True)
        lbl_inst.setStyleSheet(
            "background:#EBF8FF; color:#1A5276; border:1px solid #AED6F1;"
            " border-radius:6px; padding:10px; font-size:12px;"
        )
        root.addWidget(lbl_inst)

        # Búsqueda rápida
        self._inp_search = QLineEdit()
        self._inp_search.setPlaceholderText("🔍  Filtrar lista por nombre...")
        self._inp_search.setClearButtonEnabled(True)
        self._inp_search.textChanged.connect(self._filter_list)
        root.addWidget(self._inp_search)

        # Lista con checkboxes
        self._list_scroll = QScrollArea()
        self._list_scroll.setWidgetResizable(True)
        self._list_scroll.setFrameShape(QFrame.Shape.NoFrame)
        list_container = QWidget()
        self._list_layout = QVBoxLayout(list_container)
        self._list_layout.setSpacing(4)
        self._list_layout.setContentsMargins(4, 4, 4, 4)
        self._checkboxes: list[tuple[QCheckBox, int, str]] = []  # (cb, id, nombre)
        for c in self._clientes:
            cb = QCheckBox(c.get("razon_social", ""))
            cb.setProperty("cliente_id", c.get("id"))
            self._checkboxes.append((cb, c.get("id"), c.get("razon_social", "")))
            self._list_layout.addWidget(cb)
        self._list_layout.addStretch()
        self._list_scroll.setWidget(list_container)
        root.addWidget(self._list_scroll, stretch=1)

        # Combo de canónico
        frm_canon = QFormLayout()
        frm_canon.setLabelAlignment(Qt.AlignmentFlag.AlignRight)
        self._cmb_canonico = QComboBox()
        for c in self._clientes:
            self._cmb_canonico.addItem(c.get("razon_social", ""), c.get("id"))
        frm_canon.addRow("Registro Principal (canónico):", self._cmb_canonico)
        root.addLayout(frm_canon)

        # Preview de impacto
        self._lbl_preview = QLabel("Selecciona al menos 2 registros para ver el resumen.")
        self._lbl_preview.setStyleSheet("color:#86868B; font-size:11px;")
        root.addWidget(self._lbl_preview)

        # Botones
        btns = QDialogButtonBox()
        self._btn_merge = btns.addButton("🔗  Fusionar", QDialogButtonBox.ButtonRole.AcceptRole)
        self._btn_merge.setProperty("class", "primary")
        btns.addButton("Cancelar", QDialogButtonBox.ButtonRole.RejectRole)
        btns.accepted.connect(self._on_merge)
        btns.rejected.connect(self.reject)
        root.addWidget(btns)

        # Conectar checkboxes para preview
        for cb, _, _ in self._checkboxes:
            cb.stateChanged.connect(self._update_preview)

    def _filter_list(self, text: str):
        q = text.strip().lower()
        for cb, _, nombre in self._checkboxes:
            cb.setVisible(not q or q in nombre.lower())

    def _update_preview(self):
        checked = [(cid, nombre) for cb, cid, nombre in self._checkboxes if cb.isChecked()]
        if len(checked) < 2:
            self._lbl_preview.setText("Selecciona al menos 2 registros para ver el resumen.")
            return
        names = ", ".join(n for _, n in checked[:3])
        if len(checked) > 3:
            names += f" y {len(checked) - 3} más"
        self._lbl_preview.setText(
            f"✅ Se fusionarán <b>{len(checked)}</b> registros → Principal: "
            f"<b>{self._cmb_canonico.currentText()}</b><br>"
            f"Duplicados: {names}"
        )

    def _on_merge(self):
        checked_ids = [cid for cb, cid, _ in self._checkboxes if cb.isChecked()]
        canonico_id = self._cmb_canonico.currentData()
        if len(checked_ids) < 2:
            QMessageBox.warning(self, "Selección insuficiente",
                                "Selecciona al menos 2 clientes para fusionar.")
            return
        if canonico_id not in checked_ids:
            QMessageBox.warning(self, "Canónico no seleccionado",
                                "El registro principal debe estar marcado en la lista.")
            return
        self._canonico_id = canonico_id
        self._dup_ids = [cid for cid in checked_ids if cid != canonico_id]
        self.accept()

    def get_result(self) -> tuple[int, list[int]]:
        """Retorna (canonico_id, [dup_ids])."""
        return self._canonico_id, self._dup_ids


class _FusionSucursalesDialog(QDialog):
    """Modal para fusionar sucursales duplicadas dentro del mismo cliente."""

    def __init__(self, sucursales: list[dict], cliente_nombre: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle("🔗  Fusionar Sucursales Duplicadas")
        self.setMinimumSize(580, 440)
        self.setModal(True)
        self._sucursales = sucursales
        self._cliente_nombre = cliente_nombre
        self._canonico_id: int | None = None
        self._dup_ids: list[int] = []
        self._setup_ui()

    def _setup_ui(self):
        root = QVBoxLayout(self)
        root.setSpacing(12)
        root.setContentsMargins(20, 20, 20, 20)

        hdr = QLabel(f"Cliente: {self._cliente_nombre}")
        hdr.setStyleSheet(
            "background:#F0FFF4; color:#1A6134; border:1px solid #9AE6B4;"
            " border-radius:6px; padding:8px; font-weight:600; font-size:12px;"
        )
        root.addWidget(hdr)

        lbl_inst = QLabel(
            "Marca las sucursales a fusionar y elige la <b>Sucursal Principal</b> (canónica)."
        )
        lbl_inst.setWordWrap(True)
        lbl_inst.setStyleSheet("color:#86868B; font-size:12px;")
        root.addWidget(lbl_inst)

        # Lista
        list_scroll = QScrollArea()
        list_scroll.setWidgetResizable(True)
        list_scroll.setFrameShape(QFrame.Shape.NoFrame)
        list_container = QWidget()
        list_lay = QVBoxLayout(list_container)
        list_lay.setSpacing(4)
        self._checkboxes: list[tuple[QCheckBox, int, str]] = []
        for s in self._sucursales:
            nombre = s.get("nombre_sucursal", "")
            cb = QCheckBox(f"{nombre}  –  {s.get('direccion', '')[:60]}")
            self._checkboxes.append((cb, s.get("id"), nombre))
            list_lay.addWidget(cb)
        list_lay.addStretch()
        list_scroll.setWidget(list_container)
        root.addWidget(list_scroll, stretch=1)

        frm = QFormLayout()
        frm.setLabelAlignment(Qt.AlignmentFlag.AlignRight)
        self._cmb_canonico = QComboBox()
        for s in self._sucursales:
            self._cmb_canonico.addItem(s.get("nombre_sucursal", ""), s.get("id"))
        frm.addRow("Sucursal Principal:", self._cmb_canonico)
        root.addLayout(frm)

        btns = QDialogButtonBox()
        btn_merge = btns.addButton("🔗  Fusionar Sucursales", QDialogButtonBox.ButtonRole.AcceptRole)
        btn_merge.setProperty("class", "primary")
        btns.addButton("Cancelar", QDialogButtonBox.ButtonRole.RejectRole)
        btns.accepted.connect(self._on_merge)
        btns.rejected.connect(self.reject)
        root.addWidget(btns)

    def _on_merge(self):
        checked_ids = [sid for cb, sid, _ in self._checkboxes if cb.isChecked()]
        canonico_id = self._cmb_canonico.currentData()
        if len(checked_ids) < 2:
            QMessageBox.warning(self, "Selección insuficiente",
                                "Selecciona al menos 2 sucursales para fusionar.")
            return
        if canonico_id not in checked_ids:
            QMessageBox.warning(self, "Canónico no seleccionado",
                                "La sucursal principal debe estar marcada en la lista.")
            return
        self._canonico_id = canonico_id
        self._dup_ids = [sid for sid in checked_ids if sid != canonico_id]
        self.accept()

    def get_result(self) -> tuple[int, list[int]]:
        return self._canonico_id, self._dup_ids


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
# Diálogos para Sucursales y Equipos
# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class _SucursalEditDialog(QDialog):
    """Diálogo de alta / edición de Sucursal / Planta."""

    def __init__(self, cliente_id: int, cliente_nombre: str,
                 data: dict = None, parent=None):

        super().__init__(parent)
        self._cliente_id = cliente_id
        self._data = data or {}
        is_new = not bool(data)
        self.setWindowTitle("Nueva Sucursal / Planta" if is_new else "Editar Sucursal / Planta")
        self.setMinimumWidth(480)
        self.setModal(True)

        root = QVBoxLayout(self)
        root.setSpacing(14)
        root.setContentsMargins(20, 20, 20, 20)

        # Encabezado informativo
        hdr = QLabel(f"Cliente: {cliente_nombre}")
        hdr.setStyleSheet(
            "background:#EBF8FF; color:#1A5276; border:1px solid #AED6F1;"
            " border-radius:6px; padding:6px 10px; font-size:12px; font-weight:600;"
        )
        root.addWidget(hdr)

        form = QFormLayout()
        form.setSpacing(10)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignRight)

        self._inp_nombre = QLineEdit()
        self._inp_nombre.setPlaceholderText("Ej. Planta Querétaro, Planta SLP")
        self._inp_nombre.setFixedHeight(36)
        if self._data.get("nombre_sucursal"):
            self._inp_nombre.setText(str(self._data["nombre_sucursal"]))
        form.addRow("Nombre / Planta *:", self._inp_nombre)

        self._inp_direccion = QLineEdit()
        self._inp_direccion.setPlaceholderText("Dirección completa de la planta")
        self._inp_direccion.setFixedHeight(36)
        if self._data.get("direccion"):
            self._inp_direccion.setText(str(self._data["direccion"]))
        form.addRow("Dirección *:", self._inp_direccion)

        self._inp_contacto = QLineEdit()
        self._inp_contacto.setPlaceholderText("Nombre del contacto en planta (opcional)")
        self._inp_contacto.setFixedHeight(36)
        if self._data.get("contacto_nombre"):
            self._inp_contacto.setText(str(self._data["contacto_nombre"]))
        form.addRow("Contacto:", self._inp_contacto)

        self._inp_telefono = QLineEdit()
        self._inp_telefono.setPlaceholderText("Teléfono del contacto (opcional)")
        self._inp_telefono.setFixedHeight(36)
        if self._data.get("contacto_telefono"):
            self._inp_telefono.setText(str(self._data["contacto_telefono"]))
        form.addRow("Teléfono:", self._inp_telefono)

        root.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        ok = buttons.button(QDialogButtonBox.StandardButton.Ok)
        if ok:
            ok.setText("Guardar")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _validate_and_accept(self):
        if not self._inp_nombre.text().strip():
            QMessageBox.warning(self, "Campo requerido", "El Nombre de la Sucursal es obligatorio.")
            self._inp_nombre.setFocus()
            return
        if not self._inp_direccion.text().strip():
            QMessageBox.warning(self, "Campo requerido", "La Dirección es obligatoria.")
            self._inp_direccion.setFocus()
            return
        self.accept()

    def get_data(self) -> dict:
        return {
            "cliente_id":        self._cliente_id,
            "nombre_sucursal":   self._inp_nombre.text().strip(),
            "direccion":         self._inp_direccion.text().strip(),
            "contacto_nombre":   self._inp_contacto.text().strip() or None,
            "contacto_telefono": self._inp_telefono.text().strip() or None,
        }


class _EquipoEditDialog(QDialog):
    """Diálogo de alta / edición de Equipo / Báscula en una Sucursal."""

    def __init__(self, sucursal_id: int, sucursal_nombre: str,
                 data: dict = None, parent=None):
        super().__init__(parent)
        self._sucursal_id = sucursal_id
        self._data = data or {}
        is_new = not bool(data)
        self.setWindowTitle("Dar de Alta Equipo" if is_new else "Editar Equipo / Báscula")
        self.setMinimumWidth(500)
        self.setModal(True)

        root = QVBoxLayout(self)
        root.setSpacing(14)
        root.setContentsMargins(20, 20, 20, 20)

        hdr = QLabel(f"Planta: {sucursal_nombre}")
        hdr.setStyleSheet(
            "background:#F0FFF4; color:#1A6134; border:1px solid #9AE6B4;"
            " border-radius:6px; padding:6px 10px; font-size:12px; font-weight:600;"
        )
        root.addWidget(hdr)

        form = QFormLayout()
        form.setSpacing(10)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignRight)

        def _inp(placeholder: str, key: str, required: bool = False) -> QLineEdit:
            le = QLineEdit()
            le.setPlaceholderText(placeholder)
            le.setFixedHeight(34)
            if self._data.get(key):
                le.setText(str(self._data[key]))
            return le

        self._inp_serie  = _inp("Número de Serie (obligatorio)", "numero_serie", True)
        self._inp_tag    = _inp("Ej. BASC-01, PES-003", "id_indicador_equipo")
        self._inp_marca  = _inp("Ej. Rice Lake, Mettler Toledo", "marca")
        self._inp_modelo = _inp("Ej. IQ355, ICS449", "modelo")
        self._inp_cap    = _inp("Ej. 500 kg, 5 t", "capacidad_maxima")
        self._inp_div    = _inp("Ej. 200 g, 0.5 kg", "division_minima")
        self._inp_ubic   = _inp("Ej. Embarques, Nave 2", "ubicacion_interna")
        self._inp_tipo   = _inp("Ej. Báscula de plataforma digital", "tipo_instrumento")

        form.addRow("Número de Serie *:", self._inp_serie)
        form.addRow("Tag / ID Planta:", self._inp_tag)
        form.addRow("Marca:", self._inp_marca)
        form.addRow("Modelo:", self._inp_modelo)
        form.addRow("Capacidad Máxima:", self._inp_cap)
        form.addRow("División Mínima:", self._inp_div)
        form.addRow("Ubicación Interna:", self._inp_ubic)
        form.addRow("Tipo de Instrumento:", self._inp_tipo)

        root.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        ok = buttons.button(QDialogButtonBox.StandardButton.Ok)
        if ok:
            ok.setText("Guardar Equipo")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        root.addWidget(buttons)

    def _validate_and_accept(self):
        if not self._inp_serie.text().strip():
            QMessageBox.warning(self, "Campo requerido", "El Número de Serie es obligatorio.")
            self._inp_serie.setFocus()
            return
        self.accept()

    def get_data(self) -> dict:
        return {
            "sucursal_id":         self._sucursal_id,
            "numero_serie":        self._inp_serie.text().strip(),
            "id_indicador_equipo": self._inp_tag.text().strip() or None,
            "marca":               self._inp_marca.text().strip() or None,
            "modelo":              self._inp_modelo.text().strip() or None,
            "capacidad_maxima":    self._inp_cap.text().strip() or None,
            "division_minima":     self._inp_div.text().strip() or None,
            "ubicacion_interna":   self._inp_ubic.text().strip() or None,
            "tipo_instrumento":    self._inp_tipo.text().strip() or None,
        }


# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class ClientesSucursalesTab(QWidget):
    """
    Tab de Clientes con panel triple:
      ┌─────────────────────────────────────┐
      │  CLIENTES (tabla)                   │
      ├─────────────────────────────────────┤
      │  SUCURSALES del cliente seleccionado│
      ├─────────────────────────────────────┤
      │  EQUIPOS de la sucursal seleccionada│
      └─────────────────────────────────────┘
    """

    def __init__(self, cliente_repo, sucursal_repo, equipo_repo, parent=None):
        super().__init__(parent)
        self._cliente_repo  = cliente_repo
        self._sucursal_repo = sucursal_repo
        self._equipo_repo   = equipo_repo
        self._clientes:  list[dict] = []
        self._sucursales: list[dict] = []
        self._equipos:   list[dict] = []
        self._setup_ui()
        self._load_clientes()

    # ── Setup UI ───────────────────────────────────────────────────────────────
    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(12, 12, 12, 12)
        root.setSpacing(8)

        # ── Panel Clientes ────────────────────────────────────────────────────
        self._grp_clientes = QGroupBox("🏢  Clientes")
        self._grp_clientes.setStyleSheet(
            "QGroupBox { font-weight:700; font-size:13px; border:1px solid #D1D1D6;"
            " border-radius:8px; margin-top:8px; padding:8px 4px; }"
            "QGroupBox::title { subcontrol-origin:margin; left:12px; padding:0 6px; color:#1D1D1F; }"
        )
        grp_lay = QVBoxLayout(self._grp_clientes)
        grp_lay.setContentsMargins(8, 8, 8, 8)
        grp_lay.setSpacing(6)

        # Toolbar clientes
        tb_cl = QHBoxLayout()
        tb_cl.setSpacing(6)
        self._btn_cl_new  = QPushButton("➕  Nuevo")
        self._btn_cl_new.setProperty("class", "primary")
        self._btn_cl_new.clicked.connect(self._new_cliente)
        tb_cl.addWidget(self._btn_cl_new)

        self._btn_cl_edit = QPushButton("✏️  Editar")
        self._btn_cl_edit.clicked.connect(self._edit_cliente)
        tb_cl.addWidget(self._btn_cl_edit)

        self._btn_cl_del = QPushButton("❎  Desactivar")
        self._btn_cl_del.setProperty("class", "danger")
        self._btn_cl_del.clicked.connect(self._delete_cliente)
        tb_cl.addWidget(self._btn_cl_del)

        self._btn_cl_hard_del = QPushButton("🗑️  Eliminar Definitivo")
        self._btn_cl_hard_del.setStyleSheet(
            "background:#FF3B30; color:white; border:none; border-radius:6px;"
            " padding:6px 12px; font-weight:700;"
        )
        self._btn_cl_hard_del.clicked.connect(self._hard_delete_cliente)
        tb_cl.addWidget(self._btn_cl_hard_del)

        self._btn_cl_merge = QPushButton("🔗  Fusionar")
        self._btn_cl_merge.setStyleSheet(
            "background:#5856D6; color:white; border:none; border-radius:6px;"
            " padding:6px 12px; font-weight:600;"
        )
        self._btn_cl_merge.clicked.connect(self._merge_clientes)
        tb_cl.addWidget(self._btn_cl_merge)
        tb_cl.addStretch()

        btn_refresh = QPushButton("↻  Actualizar")
        btn_refresh.clicked.connect(self._load_clientes)
        tb_cl.addWidget(btn_refresh)
        grp_lay.addLayout(tb_cl)

        # Barra de búsqueda rápida
        search_row = QHBoxLayout()
        self._inp_search = QLineEdit()
        self._inp_search.setPlaceholderText("🔍  Buscar cliente por nombre...")
        self._inp_search.setClearButtonEnabled(True)
        self._inp_search.textChanged.connect(self._filter_clientes)
        search_row.addWidget(self._inp_search)
        grp_lay.addLayout(search_row)

        self._tbl_clientes = QTableWidget(0, 3)
        self._tbl_clientes.setHorizontalHeaderLabels(["ID", "Razón Social", "Dirección"])
        self._tbl_clientes.verticalHeader().setVisible(False)
        self._tbl_clientes.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._tbl_clientes.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._tbl_clientes.setAlternatingRowColors(True)
        self._tbl_clientes.setMinimumHeight(200)
        SP = QSizePolicy
        self._tbl_clientes.setSizePolicy(SP.Policy.Expanding, SP.Policy.Expanding)
        self._tbl_clientes.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        self._tbl_clientes.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self._tbl_clientes.itemSelectionChanged.connect(self._on_cliente_selected)
        self._tbl_clientes.doubleClicked.connect(self._edit_cliente)
        grp_lay.addWidget(self._tbl_clientes, stretch=3)
        root.addWidget(self._grp_clientes, stretch=3)

        # ── Panel Sucursales ──────────────────────────────────────────────────
        self._grp_sucursales = QGroupBox("🏭  Sucursales / Plantas  —  (selecciona un cliente)")
        self._grp_sucursales.setStyleSheet(
            "QGroupBox { font-weight:700; font-size:13px; border:1px solid #A5C8E1;"
            " border-radius:8px; margin-top:8px; padding:8px 4px; background:#F0F8FF; }"
            "QGroupBox::title { subcontrol-origin:margin; left:12px; padding:0 6px; color:#1A5276; }"
        )
        grp_suc = QVBoxLayout(self._grp_sucursales)
        grp_suc.setContentsMargins(8, 8, 8, 8)
        grp_suc.setSpacing(6)

        tb_suc = QHBoxLayout()
        tb_suc.setSpacing(6)
        self._btn_suc_new  = QPushButton("➕  Nueva Sucursal")
        self._btn_suc_new.setProperty("class", "primary")
        self._btn_suc_new.setEnabled(False)
        self._btn_suc_new.clicked.connect(self._new_sucursal)
        tb_suc.addWidget(self._btn_suc_new)

        self._btn_suc_edit = QPushButton("✏️  Editar")
        self._btn_suc_edit.setEnabled(False)
        self._btn_suc_edit.clicked.connect(self._edit_sucursal)
        tb_suc.addWidget(self._btn_suc_edit)

        self._btn_suc_del = QPushButton("❎  Desactivar")
        self._btn_suc_del.setProperty("class", "danger")
        self._btn_suc_del.setEnabled(False)
        self._btn_suc_del.clicked.connect(self._delete_sucursal)
        tb_suc.addWidget(self._btn_suc_del)

        self._btn_suc_hard_del = QPushButton("🗑️  Eliminar Definitivo")
        self._btn_suc_hard_del.setEnabled(False)
        self._btn_suc_hard_del.setStyleSheet(
            "background:#FF3B30; color:white; border:none; border-radius:6px;"
            " padding:6px 12px; font-weight:700;"
        )
        self._btn_suc_hard_del.clicked.connect(self._hard_delete_sucursal)
        tb_suc.addWidget(self._btn_suc_hard_del)

        self._btn_suc_merge = QPushButton("🔗  Fusionar")
        self._btn_suc_merge.setEnabled(False)
        self._btn_suc_merge.setStyleSheet(
            "background:#5856D6; color:white; border:none; border-radius:6px;"
            " padding:6px 12px; font-weight:600;"
        )
        self._btn_suc_merge.clicked.connect(self._merge_sucursales)
        tb_suc.addWidget(self._btn_suc_merge)
        tb_suc.addStretch()
        grp_suc.addLayout(tb_suc)

        # Barra de búsqueda de sucursales
        suc_search_row = QHBoxLayout()
        self._inp_search_suc = QLineEdit()
        self._inp_search_suc.setPlaceholderText("🔍  Buscar sucursal por nombre, dirección o contacto...")
        self._inp_search_suc.setClearButtonEnabled(True)
        self._inp_search_suc.textChanged.connect(self._filter_sucursales)
        suc_search_row.addWidget(self._inp_search_suc)
        grp_suc.addLayout(suc_search_row)

        self._tbl_sucursales = QTableWidget(0, 5)
        self._tbl_sucursales.setHorizontalHeaderLabels(
            ["ID", "Nombre / Planta", "Dirección", "Contacto", "Teléfono"]
        )
        self._tbl_sucursales.verticalHeader().setVisible(False)
        self._tbl_sucursales.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._tbl_sucursales.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._tbl_sucursales.setAlternatingRowColors(True)
        self._tbl_sucursales.setMinimumHeight(140)
        SP = QSizePolicy
        self._tbl_sucursales.setSizePolicy(SP.Policy.Expanding, SP.Policy.Expanding)
        self._tbl_sucursales.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        self._tbl_sucursales.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        self._tbl_sucursales.itemSelectionChanged.connect(self._on_sucursal_selected)
        self._tbl_sucursales.doubleClicked.connect(self._edit_sucursal)
        grp_suc.addWidget(self._tbl_sucursales, stretch=2)
        root.addWidget(self._grp_sucursales, stretch=2)

        # ── Panel Equipos ─────────────────────────────────────────────────────
        self._grp_equipos = QGroupBox("⚖️  Equipos / Básculas  —  (selecciona una planta)")
        self._grp_equipos.setStyleSheet(
            "QGroupBox { font-weight:700; font-size:13px; border:1px solid #9AE6B4;"
            " border-radius:8px; margin-top:8px; padding:8px 4px; background:#F0FFF4; }"
            "QGroupBox::title { subcontrol-origin:margin; left:12px; padding:0 6px; color:#1A6134; }"
        )
        grp_eq = QVBoxLayout(self._grp_equipos)
        grp_eq.setContentsMargins(8, 8, 8, 8)
        grp_eq.setSpacing(6)

        tb_eq = QHBoxLayout()
        tb_eq.setSpacing(6)
        self._btn_eq_new  = QPushButton("➕  Dar de Alta Equipo")
        self._btn_eq_new.setProperty("class", "primary")
        self._btn_eq_new.setEnabled(False)
        self._btn_eq_new.clicked.connect(self._new_equipo)
        tb_eq.addWidget(self._btn_eq_new)

        self._btn_eq_edit = QPushButton("✏️  Editar")
        self._btn_eq_edit.setEnabled(False)
        self._btn_eq_edit.clicked.connect(self._edit_equipo)
        tb_eq.addWidget(self._btn_eq_edit)

        self._btn_eq_del = QPushButton("❎  Dar de Baja")
        self._btn_eq_del.setProperty("class", "danger")
        self._btn_eq_del.setEnabled(False)
        self._btn_eq_del.clicked.connect(self._delete_equipo)
        tb_eq.addWidget(self._btn_eq_del)

        self._btn_eq_hard_del = QPushButton("🗑️  Eliminar Definitivo")
        self._btn_eq_hard_del.setEnabled(False)
        self._btn_eq_hard_del.setStyleSheet(
            "background:#FF3B30; color:white; border:none; border-radius:6px;"
            " padding:6px 12px; font-weight:700;"
        )
        self._btn_eq_hard_del.clicked.connect(self._hard_delete_equipo)
        tb_eq.addWidget(self._btn_eq_hard_del)
        tb_eq.addStretch()
        grp_eq.addLayout(tb_eq)

        # Barra de búsqueda de equipos
        eq_search_row = QHBoxLayout()
        self._inp_search_eq = QLineEdit()
        self._inp_search_eq.setPlaceholderText("🔍  Buscar equipo por N/S, Tag/ID, Marca, Modelo o Ubicación...")
        self._inp_search_eq.setClearButtonEnabled(True)
        self._inp_search_eq.textChanged.connect(self._filter_equipos)
        eq_search_row.addWidget(self._inp_search_eq)
        grp_eq.addLayout(eq_search_row)

        self._tbl_equipos = QTableWidget(0, 8)
        self._tbl_equipos.setHorizontalHeaderLabels([
            "ID", "Tag / ID", "Marca", "Modelo", "N/S", "Capacidad", "Div. Mín.", "Ubicación"
        ])
        self._tbl_equipos.verticalHeader().setVisible(False)
        self._tbl_equipos.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self._tbl_equipos.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self._tbl_equipos.setAlternatingRowColors(True)
        self._tbl_equipos.setMinimumHeight(180)
        SP = QSizePolicy
        self._tbl_equipos.setSizePolicy(SP.Policy.Expanding, SP.Policy.Expanding)
        self._tbl_equipos.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        self._tbl_equipos.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeMode.Stretch)
        self._tbl_equipos.itemSelectionChanged.connect(self._on_equipo_selected)
        self._tbl_equipos.doubleClicked.connect(self._edit_equipo)
        grp_eq.addWidget(self._tbl_equipos, stretch=3)
        root.addWidget(self._grp_equipos, stretch=3)

    # ── Carga de datos ─────────────────────────────────────────────────────────
    def _load_clientes(self) -> None:
        try:
            self._clientes = self._cliente_repo.get_all()
        except Exception as exc:
            logger.error("Error cargando clientes: %s", exc)
            self._clientes = []
        self._tbl_clientes.setRowCount(0)
        for r in self._clientes:
            i = self._tbl_clientes.rowCount()
            self._tbl_clientes.insertRow(i)
            self._tbl_clientes.setRowHeight(i, 34)
            for col, val in enumerate([r.get("id"), r.get("razon_social"), r.get("direccion")]):
                item = QTableWidgetItem(str(val) if val else "")
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col == 0:
                    item.setData(Qt.ItemDataRole.UserRole, r.get("id"))
                    item.setForeground(QColor("#86868B"))
                self._tbl_clientes.setItem(i, col, item)
        # Limpiar paneles inferiores
        self._tbl_sucursales.setRowCount(0)
        self._tbl_equipos.setRowCount(0)
        self._sucursales.clear()
        self._equipos.clear()
        for btn in [self._btn_suc_new, self._btn_suc_edit, self._btn_suc_del]:
            btn.setEnabled(False)
        for btn in [self._btn_eq_new, self._btn_eq_edit, self._btn_eq_del]:
            btn.setEnabled(False)
        self._grp_sucursales.setTitle("🏭  Sucursales / Plantas  —  (selecciona un cliente)")
        self._grp_equipos.setTitle("⚖️  Equipos / Básculas  —  (selecciona una planta)")
        # Aplicar filtro de búsqueda si hay texto
        self._filter_clientes(self._inp_search.text())

    def _filter_clientes(self, text: str) -> None:
        """Filtra filas de la tabla de clientes en tiempo real por texto."""
        q = text.strip().lower()
        for row in range(self._tbl_clientes.rowCount()):
            visible = True
            if q:
                nombre_item = self._tbl_clientes.item(row, 1)
                nombre = nombre_item.text().lower() if nombre_item else ""
                visible = q in nombre
            self._tbl_clientes.setRowHidden(row, not visible)


    def _load_sucursales(self, cliente_id: int, cliente_nombre: str) -> None:
        try:
            self._sucursales = self._sucursal_repo.get_by_cliente(cliente_id)
        except Exception as exc:
            logger.error("Error cargando sucursales: %s", exc)
            self._sucursales = []
        self._tbl_sucursales.setRowCount(0)
        for r in self._sucursales:
            i = self._tbl_sucursales.rowCount()
            self._tbl_sucursales.insertRow(i)
            self._tbl_sucursales.setRowHeight(i, 34)
            for col, val in enumerate([
                r.get("id"), r.get("nombre_sucursal"), r.get("direccion"),
                r.get("contacto_nombre"), r.get("contacto_telefono"),
            ]):
                item = QTableWidgetItem(str(val) if val else "")
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col == 0:
                    item.setData(Qt.ItemDataRole.UserRole, r.get("id"))
                    item.setForeground(QColor("#86868B"))
                self._tbl_sucursales.setItem(i, col, item)
        n = len(self._sucursales)
        self._grp_sucursales.setTitle(f"🏭  Sucursales / Plantas de '{cliente_nombre}'  ({n})")
        self._btn_suc_new.setEnabled(True)
        # Limpiar equipos
        self._tbl_equipos.setRowCount(0)
        self._equipos.clear()
        for btn in [self._btn_eq_new, self._btn_eq_edit, self._btn_eq_del]:
            btn.setEnabled(False)
        self._grp_equipos.setTitle("⚖️  Equipos / Básculas  —  (selecciona una planta)")

    def _load_equipos(self, sucursal_id: int, sucursal_nombre: str) -> None:
        try:
            self._equipos = self._equipo_repo.get_by_sucursal(sucursal_id)
        except Exception as exc:
            logger.error("Error cargando equipos: %s", exc)
            self._equipos = []
        self._tbl_equipos.setRowCount(0)
        for r in self._equipos:
            i = self._tbl_equipos.rowCount()
            self._tbl_equipos.insertRow(i)
            self._tbl_equipos.setRowHeight(i, 34)
            for col, val in enumerate([
                r.get("id"), r.get("id_indicador_equipo"), r.get("marca"),
                r.get("modelo"), r.get("numero_serie"), r.get("capacidad_maxima"),
                r.get("division_minima"), r.get("ubicacion_interna"),
            ]):
                item = QTableWidgetItem(str(val) if val else "")
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col == 0:
                    item.setData(Qt.ItemDataRole.UserRole, r.get("id"))
                    item.setForeground(QColor("#86868B"))
                self._tbl_equipos.setItem(i, col, item)
        n = len(self._equipos)
        self._grp_equipos.setTitle(f"⚖️  Equipos de '{sucursal_nombre}'  ({n} registradas)")
        self._btn_eq_new.setEnabled(True)

    # ── Slots de selección ────────────────────────────────────────────────────
    # ── Slots de selección (ver definiciones completas al final de la clase) ────

    # ── CRUD Clientes ─────────────────────────────────────────────────────────
    def _get_selected_cliente(self) -> Optional[dict]:
        row = self._tbl_clientes.currentRow()
        if row < 0:
            return None
        item = self._tbl_clientes.item(row, 0)
        if not item:
            return None
        cid = item.data(Qt.ItemDataRole.UserRole)
        return next((c for c in self._clientes if c.get("id") == cid), None)

    def _new_cliente(self) -> None:
        dlg = _EditDialog(
            "Nuevo Cliente",
            [
                ("Razón Social", "razon_social", "Nombre completo de la empresa"),
                ("Dirección",    "direccion",    "Dirección completa (Opcional)"),
            ],
            parent=self,
        )
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            razon = (data.get("razon_social") or "").strip()
            if not razon:
                QMessageBox.warning(self, "Campo requerido",
                    "La Razón Social es obligatoria.")
                return
            try:
                nuevo = self._cliente_repo.create(data)
                # Limpiar búsqueda para que el cliente nuevo sea visible
                if hasattr(self, '_search_clientes') and self._search_clientes:
                    self._search_clientes.clear()
                self._load_clientes()
                _broadcast_catalogs_update()
                nuevo_id = nuevo.get('id', '?')
                QMessageBox.information(self, "Cliente Registrado",
                    f"✅ Cliente '{razon}' creado correctamente.\nID asignado: {nuevo_id}")
            except Exception as exc:
                QMessageBox.critical(self, "Error al Crear Cliente",
                    f"No se pudo guardar el cliente en la base de datos:\n\n{exc}")

    def _edit_cliente(self) -> None:
        data = self._get_selected_cliente()
        if not data:
            return
        dlg = _EditDialog(
            "Editar Cliente",
            [
                ("Razón Social", "razon_social", "Nombre completo de la empresa"),
                ("Dirección",    "direccion",    "Dirección completa"),
            ],
            data=data, parent=self,
        )
        if dlg.exec() == QDialog.DialogCode.Accepted:
            try:
                self._cliente_repo.update(data["id"], dlg.get_data())
                self._load_clientes()
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo actualizar:\n{exc}")

    def _delete_cliente(self) -> None:
        data = self._get_selected_cliente()
        if not data:
            return
        reply = QMessageBox.question(
            self, "Confirmar",
            f"¿Desactivar al cliente '{data.get('razon_social')}'?\n"
            "También desactivará sus sucursales y equipos asociados.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply == QMessageBox.StandardButton.Yes:
            try:
                self._cliente_repo.delete(data["id"])
                self._load_clientes()
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo desactivar:\n{exc}")

    # ── CRUD Sucursales ────────────────────────────────────────────────────────
    def _get_selected_sucursal(self) -> Optional[dict]:
        row = self._tbl_sucursales.currentRow()
        if row < 0:
            return None
        item = self._tbl_sucursales.item(row, 0)
        if not item:
            return None
        sid = item.data(Qt.ItemDataRole.UserRole)
        return next((s for s in self._sucursales if s.get("id") == sid), None)

    def _get_selected_cliente_id(self) -> Optional[int]:
        cl = self._get_selected_cliente()
        return cl["id"] if cl else None

    def _new_sucursal(self) -> None:
        cl = self._get_selected_cliente()
        if not cl:
            QMessageBox.warning(self, "Seleccionar Cliente", "Primero selecciona un cliente de la lista.")
            return
        dlg = _SucursalEditDialog(cl["id"], cl.get("razon_social", ""), parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            nombre = (data.get("nombre_sucursal") or "").strip()
            if not nombre:
                QMessageBox.warning(self, "Campo Requerido", "El Nombre/Planta es obligatorio.")
                return
            try:
                nueva = self._sucursal_repo.create(data)
                if hasattr(self, '_inp_search_suc') and self._inp_search_suc:
                    self._inp_search_suc.clear()
                self._load_sucursales(cl["id"], cl.get("razon_social", ""))
                _broadcast_catalogs_update()
                nuevo_id = nueva.get("id", "?")
                QMessageBox.information(
                    self, "Éxito",
                    f"✅ Sucursal/Planta '{nombre}' guardada exitosamente (ID: {nuevo_id})."
                )
            except Exception as exc:
                QMessageBox.critical(self, "Error al Guardar Sucursal", f"Fallo al registrar en PostgreSQL:\n\n{exc}")

    def _edit_sucursal(self) -> None:
        suc = self._get_selected_sucursal()
        cl  = self._get_selected_cliente()
        if not suc or not cl:
            return
        dlg = _SucursalEditDialog(cl["id"], cl.get("razon_social", ""), data=suc, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            try:
                self._sucursal_repo.update(suc["id"], dlg.get_data())
                self._load_sucursales(cl["id"], cl.get("razon_social", ""))
                _broadcast_catalogs_update()
                QMessageBox.information(self, "Éxito", "Sucursal actualizada correctamente.")
            except Exception as exc:
                QMessageBox.critical(self, "Error al Actualizar Sucursal", f"No se pudo actualizar la sucursal:\n\n{exc}")

    def _delete_sucursal(self) -> None:
        suc = self._get_selected_sucursal()
        cl  = self._get_selected_cliente()
        if not suc:
            return
        reply = QMessageBox.question(
            self, "Confirmar",
            f"¿Desactivar la planta '{suc.get('nombre_sucursal')}'?\n"
            "También desactivará los equipos registrados en ella.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply == QMessageBox.StandardButton.Yes:
            try:
                self._sucursal_repo.delete(suc["id"])
                if cl:
                    self._load_sucursales(cl["id"], cl.get("razon_social", ""))
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo desactivar la sucursal:\n{exc}")

    # ── CRUD Equipos ───────────────────────────────────────────────────────────
    def _get_selected_equipo(self) -> Optional[dict]:
        row = self._tbl_equipos.currentRow()
        if row < 0:
            return None
        item = self._tbl_equipos.item(row, 0)
        if not item:
            return None
        eid = item.data(Qt.ItemDataRole.UserRole)
        return next((e for e in self._equipos if e.get("id") == eid), None)

    def _new_equipo(self) -> None:
        suc = self._get_selected_sucursal()
        if not suc:
            QMessageBox.warning(self, "Seleccionar Planta", "Primero selecciona una sucursal o planta de la lista.")
            return
        dlg = _EquipoEditDialog(suc["id"], suc.get("nombre_sucursal", ""), parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            serie = (data.get("numero_serie") or "").strip()
            if not serie:
                QMessageBox.warning(self, "Campo Requerido", "El Número de Serie es obligatorio.")
                return
            try:
                nuevo = self._equipo_repo.create(data)
                if hasattr(self, '_inp_search_eq') and self._inp_search_eq:
                    self._inp_search_eq.clear()
                self._load_equipos(suc["id"], suc.get("nombre_sucursal", ""))
                _broadcast_catalogs_update()
                nuevo_id = nuevo.get("id", "?")
                QMessageBox.information(
                    self, "Éxito",
                    f"✅ Equipo/Báscula N/S '{serie}' registrado correctamente (ID: {nuevo_id})."
                )
            except Exception as exc:
                QMessageBox.critical(self, "Error al Guardar Equipo", f"Fallo al registrar en PostgreSQL:\n\n{exc}")

    def _edit_equipo(self) -> None:
        eq  = self._get_selected_equipo()
        suc = self._get_selected_sucursal()
        if not eq or not suc:
            return
        dlg = _EquipoEditDialog(suc["id"], suc.get("nombre_sucursal", ""), data=eq, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            try:
                self._equipo_repo.update(eq["id"], dlg.get_data())
                self._load_equipos(suc["id"], suc.get("nombre_sucursal", ""))
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo actualizar el equipo:\n{exc}")

    def _delete_equipo(self) -> None:
        eq  = self._get_selected_equipo()
        suc = self._get_selected_sucursal()
        if not eq:
            return
        reply = QMessageBox.question(
            self, "Confirmar",
            f"¿Dar de baja la báscula N/S '{eq.get('numero_serie')}'?\n"
            "Se mantendrá en los registros históricos.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if reply == QMessageBox.StandardButton.Yes:
            try:
                self._equipo_repo.delete(eq["id"])
                if suc:
                    self._load_equipos(suc["id"], suc.get("nombre_sucursal", ""))
                _broadcast_catalogs_update()
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo dar de baja el equipo:\n{exc}")

    # ── Hard Delete (Eliminación Definitiva) ───────────────────────────────────

    def _hard_delete_cliente(self) -> None:
        data = self._get_selected_cliente()
        if not data:
            return
        nombre = data.get("razon_social", "")
        r1 = QMessageBox.question(
            self, "⚠️ Eliminar Definitivamente",
            f"¿Eliminar PERMANENTEMENTE al cliente:\n\n  «{nombre}»?\n\n"
            "Esta acción eliminará también todas sus sucursales y equipos "
            "del catálogo. NO se puede deshacer.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if r1 != QMessageBox.StandardButton.Yes:
            return
        r2 = QMessageBox.question(
            self, "Confirmar segunda vez",
            f"Confirma: ¿eliminar definitivamente «{nombre}» y toda su jerarquía?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if r2 == QMessageBox.StandardButton.Yes:
            try:
                self._cliente_repo.hard_delete(data["id"])
                self._load_clientes()
                _broadcast_catalogs_update()
                QMessageBox.information(self, "Eliminado", f"Cliente «{nombre}» eliminado definitivamente.")
            except ValueError as ve:
                QMessageBox.warning(self, "No se puede eliminar", str(ve))
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo eliminar:\n{exc}")

    def _hard_delete_sucursal(self) -> None:
        suc = self._get_selected_sucursal()
        cl  = self._get_selected_cliente()
        if not suc:
            return
        nombre = suc.get("nombre_sucursal", "")
        r = QMessageBox.question(
            self, "⚠️ Eliminar Definitivamente",
            f"¿Eliminar PERMANENTEMENTE la planta:\n\n  «{nombre}»?\n\n"
            "Se eliminarán también todos sus equipos del catálogo. NO se puede deshacer.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if r == QMessageBox.StandardButton.Yes:
            try:
                self._sucursal_repo.hard_delete(suc["id"])
                if cl:
                    self._load_sucursales(cl["id"], cl.get("razon_social", ""))
                _broadcast_catalogs_update()
                QMessageBox.information(self, "Eliminado", f"Planta «{nombre}» eliminada definitivamente.")
            except ValueError as ve:
                QMessageBox.warning(self, "No se puede eliminar", str(ve))
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo eliminar:\n{exc}")

    def _hard_delete_equipo(self) -> None:
        eq  = self._get_selected_equipo()
        suc = self._get_selected_sucursal()
        if not eq:
            return
        ns = eq.get("numero_serie", "")
        r = QMessageBox.question(
            self, "⚠️ Eliminar Definitivamente",
            f"¿Eliminar PERMANENTEMENTE la báscula N/S «{ns}»?\n\nEsta acción NO se puede deshacer.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if r == QMessageBox.StandardButton.Yes:
            try:
                self._equipo_repo.hard_delete(eq["id"])
                if suc:
                    self._load_equipos(suc["id"], suc.get("nombre_sucursal", ""))
                _broadcast_catalogs_update()
            except ValueError as ve:
                QMessageBox.warning(self, "No se puede eliminar", str(ve))
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo eliminar:\n{exc}")

    # ── Fusión de Duplicados ───────────────────────────────────────────────────

    def _merge_clientes(self) -> None:
        if not self._clientes:
            QMessageBox.information(self, "Sin datos", "No hay clientes cargados.")
            return
        dlg = _FusionClientesDialog(self._clientes, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            canonico_id, dup_ids = dlg.get_result()
            try:
                stats = self._cliente_repo.merge(canonico_id, dup_ids)
                self._load_clientes()
                _broadcast_catalogs_update()
                omitidas = stats.get('sucursales_omitidas', 0)
                msg = (
                    f"✅ Fusión realizada con éxito.\n\n"
                    f"• Sucursales movidas: {stats.get('sucursales_movidas', 0)}\n"
                    f"• OS actualizadas: {stats.get('os_actualizadas', 0)}\n"
                    f"• Duplicados desactivados: {len(dup_ids)}"
                )
                if omitidas:
                    msg += (
                        f"\n• Sucursales con nombre duplicado: {omitidas} "
                        f"(sus equipos se consolidaron en la sucursal existente)"
                    )
                QMessageBox.information(self, "Fusión completada", msg)
            except Exception as exc:
                QMessageBox.critical(self, "Error en fusión", f"No se pudo completar la fusión:\n{exc}")

    def _merge_sucursales(self) -> None:
        cl = self._get_selected_cliente()
        if not cl or not self._sucursales:
            QMessageBox.information(self, "Sin datos", "Selecciona un cliente con sucursales primero.")
            return
        dlg = _FusionSucursalesDialog(
            self._sucursales, cl.get("razon_social", ""), parent=self
        )
        if dlg.exec() == QDialog.DialogCode.Accepted:
            canonico_id, dup_ids = dlg.get_result()
            try:
                stats = self._sucursal_repo.merge(canonico_id, dup_ids)
                self._load_sucursales(cl["id"], cl.get("razon_social", ""))
                _broadcast_catalogs_update()
                QMessageBox.information(
                    self, "Fusión completada",
                    f"✅ Fusión de sucursales realizada con éxito.\n\n"
                    f"• Equipos movidos: {stats.get('equipos_movidos', 0)}\n"
                    f"• Equipos omitidos (N/S duplicados): {stats.get('equipos_omitidos', 0)}\n"
                    f"• Duplicados desactivados: {len(dup_ids)}"
                )
            except Exception as exc:
                QMessageBox.critical(self, "Error en fusión", f"No se pudo completar la fusión:\n{exc}")

    # ── Filtros de búsqueda en tiempo real ────────────────────────────────────

    def _filter_sucursales(self, text: str) -> None:
        """Filtra filas visibles de sucursales sin recargar BD."""
        q = text.strip().lower()
        for row in range(self._tbl_sucursales.rowCount()):
            if not q:
                self._tbl_sucursales.setRowHidden(row, False)
                continue
            visible = False
            for col in range(1, 5):  # columnas: nombre, dirección, contacto, teléfono
                it = self._tbl_sucursales.item(row, col)
                if it and q in it.text().lower():
                    visible = True
                    break
            self._tbl_sucursales.setRowHidden(row, not visible)

    def _filter_equipos(self, text: str) -> None:
        """Filtra filas visibles de equipos sin recargar BD."""
        q = text.strip().lower()
        for row in range(self._tbl_equipos.rowCount()):
            if not q:
                self._tbl_equipos.setRowHidden(row, False)
                continue
            visible = False
            # columnas: 1=Tag, 2=Marca, 3=Modelo, 4=N/S, 7=Ubicación
            for col in [1, 2, 3, 4, 7]:
                it = self._tbl_equipos.item(row, col)
                if it and q in it.text().lower():
                    visible = True
                    break
            self._tbl_equipos.setRowHidden(row, not visible)

    # ── Habilitación de botones extra al seleccionar ───────────────────────────

    def _on_cliente_selected(self) -> None:
        row = self._tbl_clientes.currentRow()
        if row < 0:
            return
        item = self._tbl_clientes.item(row, 0)
        if not item:
            return
        cliente_id = item.data(Qt.ItemDataRole.UserRole)
        nombre_item = self._tbl_clientes.item(row, 1)
        nombre = nombre_item.text() if nombre_item else ""
        self._load_sucursales(cliente_id, nombre)
        for btn in [self._btn_cl_edit, self._btn_cl_del, self._btn_cl_hard_del]:
            btn.setEnabled(True)
        for btn in [self._btn_suc_edit, self._btn_suc_del,
                    self._btn_suc_hard_del, self._btn_suc_merge]:
            btn.setEnabled(False)

    def _on_sucursal_selected(self) -> None:
        row = self._tbl_sucursales.currentRow()
        if row < 0:
            return
        item = self._tbl_sucursales.item(row, 0)
        if not item:
            return
        suc_id = item.data(Qt.ItemDataRole.UserRole)
        nombre_item = self._tbl_sucursales.item(row, 1)
        nombre = nombre_item.text() if nombre_item else ""
        self._load_equipos(suc_id, nombre)
        for btn in [self._btn_suc_edit, self._btn_suc_del, self._btn_suc_hard_del]:
            btn.setEnabled(True)
        self._btn_suc_merge.setEnabled(len(self._sucursales) > 1)
        for btn in [self._btn_eq_edit, self._btn_eq_del, self._btn_eq_hard_del]:
            btn.setEnabled(False)

    def _on_equipo_selected(self) -> None:
        row = self._tbl_equipos.currentRow()
        if row < 0:
            return
        for btn in [self._btn_eq_edit, self._btn_eq_del, self._btn_eq_hard_del]:
            btn.setEnabled(True)

    # Compatibilidad con _load_catalogs usado por _broadcast_catalogs_update
    def _load_catalogs(self) -> None:
        self._load_clientes()



# ════════════════════════════════════════════════════════════════════════════════════════════════════════════════════
class TecnicosTab(_CatalogTab):
    """Tab con columna Rol (badge coloreado) y diálogo dedicado con contraseña."""

    TITLE   = "Técnicos"
    COLUMNS = ["ID", "Nombre Completo", "Rol", "Usuario", "Teléfono", "Email"]

    def _get_row_values(self, r: dict) -> list:
        import json as _json

        def _roles_to_list(raw) -> list:
            """Convierte cualquier formato de roles en lista de strings."""
            if raw is None:
                return []
            if isinstance(raw, (list, tuple)):
                return [str(x).strip() for x in raw if x]
            if isinstance(raw, str):
                s = raw.strip()
                if not s:
                    return []
                if s.startswith("["):
                    try:
                        return [str(x).strip() for x in _json.loads(s) if x]
                    except Exception:
                        pass
                if s.startswith("{"):
                    inner = s.strip("{}").strip()
                    return [p.strip().strip('"') for p in inner.split(",") if p.strip()]
                if "," in s:
                    return [p.strip() for p in s.split(",") if p.strip()]
                return [s]
            return [str(raw)]

        # Priorizar campo 'roles'; fallback a 'rol'
        roles_list = _roles_to_list(r.get("roles"))
        if not roles_list:
            roles_list = _roles_to_list(r.get("rol") or "Técnico")

        roles_str = ", ".join(roles_list) if roles_list else "Técnico"
        return [
            r.get("id"),
            r.get("nombre_completo"),
            roles_str,
            r.get("usuario"),
            r.get("telefono"),
            r.get("email"),
        ]

    def _populate(self) -> None:
        """Override: pinta el badge de rol con color distinto por rol."""
        self._table.setRowCount(0)
        for row_data in self._rows:
            i = self._table.rowCount()
            self._table.insertRow(i)
            self._table.setRowHeight(i, 36)
            for col_idx, val in enumerate(self._get_row_values(row_data)):
                item = QTableWidgetItem(str(val) if val else "")
                item.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable)
                if col_idx == 0:
                    item.setData(Qt.ItemDataRole.UserRole, row_data.get("id"))
                    item.setForeground(Qt.GlobalColor.gray)
                elif col_idx == 2:   # columna Rol — badge
                    rol_str = str(val) if val else "Técnico"
                    # Usar el primer rol de la lista para determinar el color del badge
                    primer_rol = rol_str.split(",")[0].strip() if rol_str else "Técnico"
                    fg_hex, bg_hex = _ROL_BADGE.get(primer_rol, ("#1D1D1F", "#F0F0F0"))
                    item.setForeground(QColor(fg_hex))
                    item.setBackground(QColor(bg_hex))
                    f = item.font()
                    f.setBold(True)
                    item.setFont(f)
                self._table.setItem(i, col_idx, item)

    def _new_record(self) -> None:
        dlg = _TecnicoEditDialog(is_new=True, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            try:
                self._repo.create(data)
                self._load()
                _broadcast_catalogs_update()
                QMessageBox.information(self, "Éxito", f"Usuario {data.get('usuario')} creado correctamente.")
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo crear el técnico:\n{exc}")

    def _edit_record(self) -> None:
        data = self._get_selected_data()
        if not data:
            return
        dlg = _TecnicoEditDialog(is_new=False, data=data, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            new_data = dlg.get_data()
            try:
                self._repo.update(data["id"], new_data)
                self._load()
                _broadcast_catalogs_update()
                
                msg = f"Usuario {new_data.get('usuario')} actualizado correctamente."
                if new_data.get("password"):
                    msg += " La nueva contraseña ha sido establecida y ya puede iniciar sesión."
                QMessageBox.information(self, "Éxito", msg)
            except Exception as exc:
                QMessageBox.critical(self, "Error", f"No se pudo actualizar el técnico:\n{exc}")


# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550
class TipoServicioTab(_CatalogTab):
    TITLE   = "Tipos de Servicio"
    COLUMNS = ["ID", "Nombre", "Descripci\u00f3n"]
    FIELDS  = [
        ("Nombre",      "nombre",      "Ej. Calibraci\u00f3n + Ajuste"),
        ("Descripci\u00f3n", "descripcion", "Descripci\u00f3n del tipo de servicio"),
    ]

    def _get_row_values(self, r: dict) -> list:
        return [r.get("id"), r.get("nombre"), r.get("descripcion")]


# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550
class TipoInstrumentoTab(_CatalogTab):
    TITLE   = "Tipos de Instrumento"
    COLUMNS = ["ID", "Nombre", "Descripción"]
    FIELDS  = [
        ("Nombre",                 "nombre",      "Ej. Balanza Electrónica"),
        ("Descripción (opcional)", "descripcion", "Descripción del tipo de instrumento"),
    ]

    def _get_row_values(self, r: dict) -> list:
        return [r.get("id"), r.get("nombre"), r.get("descripcion")]

    def load_catalogo_tipos_instrumento(self) -> None:
        """Recarga los tipos de instrumento desde PostgreSQL y puebla la QTableWidget de inmediato."""
        self._load()

    def _new_record(self) -> None:
        dlg = _EditDialog(f"Nuevo — {self.TITLE}", self.FIELDS, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            data = dlg.get_data()
            try:
                self._repo.create(data)
                # Actualización inmediata de la vista en memoria y en la tabla
                self.load_catalogo_tipos_instrumento()
                _broadcast_catalogs_update()
                QMessageBox.information(
                    self, "Éxito",
                    f"Tipo de instrumento '{data.get('nombre')}' agregado correctamente."
                )
            except Exception as exc:
                logger.error("Error al crear tipo de instrumento: %s", exc, exc_info=True)
                err_str = str(exc)
                if "unique" in err_str.lower() or "duplicad" in err_str.lower() or "uq_" in err_str.lower():
                    detalles = f"Ya existe un tipo de instrumento con el nombre '{data.get('nombre')}'.\nPor favor usa un nombre diferente."
                else:
                    detalles = f"No se pudo guardar el tipo de instrumento en PostgreSQL:\n{exc}"
                QMessageBox.critical(self, "Error al Guardar", detalles)

    def _edit_record(self) -> None:
        data = self._get_selected_data()
        if not data:
            return
        dlg = _EditDialog(f"Editar — {self.TITLE}", self.FIELDS, data=data, parent=self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            new_data = dlg.get_data()
            try:
                self._repo.update(data["id"], new_data)
                self.load_catalogo_tipos_instrumento()
                _broadcast_catalogs_update()
                QMessageBox.information(
                    self, "Éxito",
                    f"Tipo de instrumento '{new_data.get('nombre')}' actualizado correctamente."
                )
            except Exception as exc:
                logger.error("Error al actualizar tipo de instrumento: %s", exc, exc_info=True)
                err_str = str(exc)
                if "unique" in err_str.lower() or "duplicad" in err_str.lower() or "uq_" in err_str.lower():
                    detalles = f"Ya existe un tipo de instrumento con el nombre '{new_data.get('nombre')}'.\nPor favor usa un nombre diferente."
                else:
                    detalles = f"No se pudo actualizar el tipo de instrumento en PostgreSQL:\n{exc}"
                QMessageBox.critical(self, "Error al Actualizar", detalles)


# \u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550
class CatalogosWidget(QWidget):
    """Widget principal de cat\u00e1logos con tabs para cada entidad."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._setup_ui()

    def _setup_ui(self) -> None:
        root = QVBoxLayout(self)
        root.setContentsMargins(20, 16, 20, 16)
        root.setSpacing(12)

        title = QLabel("\U0001f5c2\ufe0f  Administraci\u00f3n de Cat\u00e1logos")
        title.setStyleSheet("font-size:18px; font-weight:800; color:#1D1D1F;")
        root.addWidget(title)

        note = QLabel(
            "\u26a0\ufe0f  Acceso restringido \u2014 Los cambios aqu\u00ed afectan todas las \u00d3rdenes de Servicio"
        )
        note.setStyleSheet(
            "background:#FFF6E5; color:#FF9F0A; border:1px solid #9E6A03;"
            " border-radius:6px; padding:8px 12px; font-size:12px;"
        )
        root.addWidget(note)

        tabs = QTabWidget()
        root.addWidget(tabs)

        try:
            from models.catalogo import (
                cliente_repo, tecnico_repo,
                tipo_servicio_repo, tipo_instrumento_repo,
                sucursal_repo, equipo_sucursal_repo,
            )
            # Clientes/Sucursales/Equipos — panel triple dentro de un scroll
            cl_tab = QScrollArea()
            cl_tab.setWidgetResizable(True)
            cl_tab.setFrameShape(cl_tab.Shape.NoFrame)
            cl_inner = ClientesSucursalesTab(
                cliente_repo, sucursal_repo, equipo_sucursal_repo
            )
            cl_tab.setWidget(cl_inner)
            tabs.addTab(cl_tab,                                    "👥 Clientes")
            tabs.addTab(TecnicosTab(tecnico_repo),                 "👷 Técnicos")
            tabs.addTab(TipoServicioTab(tipo_servicio_repo),       "🔧 Tipos de Servicio")
            tabs.addTab(TipoInstrumentoTab(tipo_instrumento_repo), "⚖️ Tipos de Instrumento")
        except Exception as exc:
            error_lbl = QLabel(f"No se pudieron cargar los catálogos:\n{exc}")
            error_lbl.setStyleSheet("color:#FF3B30; padding:20px;")
            root.addWidget(error_lbl)

