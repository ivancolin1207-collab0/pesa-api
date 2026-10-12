import re
import io

path = 'ui/widgets/dashboard_widget.py'
with io.open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# A) Estatus
old_estado_label = """    @classmethod
    def _estado_label(cls, estado: str) -> str:
        \"\"\"Etiqueta del badge: verde 'Cerrado' para cualquier estado final, nunca 'Proceso'.\"\"\"
        e = str(estado or "").strip()
        if cls._is_estado_cerrado(e):
            return "Cerrado"
        if e.upper().startswith("CANCEL"):
            return "Cancelada"
        return e.capitalize() if e and e != "--" else "Proceso\"\"\""""

new_estado_label = """    @classmethod
    def _estado_label(cls, estado: str) -> str:
        e = str(estado or "").strip().lower()
        if 'pend' in e or 'sin formato' in e or 'diente' in e:
            return "Pendiente de Formato"
        if 'proc' in e:
            return "En Proceso"
        if 'cerrad' in e or 'complet' in e:
            return "Cerrado"
        if 'asig' in e:
            return "Asignada"
        if e.startswith("cancel"):
            return "Cancelada"
        return e.capitalize() if e and e != "--" else "En Proceso\"\"\""""
# We'll use regex for the whole block to be safe.
content = re.sub(
    r'@classmethod\s*def _estado_label\(cls, estado: str\) -> str:.*?return e\.capitalize\(\) if e and e != "--" else "Proceso"',
    """@classmethod
    def _estado_label(cls, estado: str) -> str:
        e = str(estado or "").strip().lower()
        if 'pend' in e or 'sin formato' in e or 'diente' in e:
            return "Pendiente de Formato"
        if 'proc' in e:
            return "En Proceso"
        if 'cerrad' in e or 'complet' in e:
            return "Cerrado"
        if 'asig' in e:
            return "Asignada"
        if e.startswith("cancel"):
            return "Cancelada"
        return e.capitalize() if e and e != "--" else "En Proceso\"\"\"""",
    content,
    flags=re.DOTALL
)

# Fix sizeHint for StatusBadgeDelegate
old_sizeHint = """        w = fm.horizontalAdvance(str(text)) + 24
        return QSize(w, 44)"""
new_sizeHint = """        w = fm.horizontalAdvance(str(text)) + 24
        return QSize(max(w, 150), 44)"""
content = content.replace(old_sizeHint, new_sizeHint)

# B) Menú Técnicos
content = content.replace('self._combo_tec_bar.addItem("Todos los Tecnicos", None)', 'self._combo_tec_bar.addItem("Todos los Técnicos", None)')
content = re.sub(r'self\._combo_tec_bar\.setMinimumWidth\(\d+\)', 'self._combo_tec_bar.setMinimumWidth(160)', content)

# C) Folio and Tipo Servicio widths
content = re.sub(r'table\.setColumnWidth\(self\._COL_FOLIO, \d+\)', 'table.setColumnWidth(self._COL_FOLIO, 160)', content)
content = re.sub(r'table\.setColumnWidth\(self\._COL_SERVICIO, \d+\)', 'table.setColumnWidth(self._COL_SERVICIO, 210)', content)

# D) Tooltip y texto de boton modalidad
content = content.replace('btn_modal = QPushButton(modal_text)', 'btn_modal = QPushButton("Cambiar a Físico" if not is_digital else "Cambiar a Digital")')
content = content.replace('btn_modal.setToolTip("Cambiar modalidad del lote (Fsico / Digital)")', 'btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")')
content = content.replace('btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")', 'btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")')
content = content.replace('btn_modal.setToolTip("Cambiar modalidad del lote (FÃ­sico / Digital)")', 'btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")')
# Catch any tooltip string
content = re.sub(r'btn_modal\.setToolTip\(".*?"\)', 'btn_modal.setToolTip("Cambiar modalidad del lote (Físico / Digital)")', content)

# Lote Folio text formatting
content = re.sub(
    r'texto_folio = f"[^"]*?\{f_ini\} al \{f_fin\}.*?"',
    r'texto_folio = f"▸ LOTE {f_ini} al {f_fin}"',
    content
)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Modifications applied successfully.")
