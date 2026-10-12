import re

path = 'ui/widgets/dashboard_widget.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update margins of inner_lay
old_margins = "self._inner_lay.setContentsMargins(28, 24, 28, 24)"
new_margins = "self._inner_lay.setContentsMargins(24, 16, 24, 24)"
if old_margins in content:
    content = content.replace(old_margins, new_margins)
else:
    print("Could not find old margins.")

# 2. Add setSizePolicy to table
old_table_init = """        self._table = QTreeWidget()
        self._configure_table(self._table)"""
new_table_init = """        self._table = QTreeWidget()
        from PyQt6.QtWidgets import QSizePolicy
        self._table.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self._configure_table(self._table)"""
if old_table_init in content:
    content = content.replace(old_table_init, new_table_init)
else:
    print("Could not find table init.")

# 3. Add stretch modes to CLIENTE and SUCURSAL
old_header_resize = """        header.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        header.setStretchLastSection(False)"""
new_header_resize = """        header.setSectionResizeMode(QHeaderView.ResizeMode.Interactive)
        header.setSectionResizeMode(self._COL_CLIENTE, QHeaderView.ResizeMode.Stretch)
        header.setSectionResizeMode(self._COL_SUCURSAL, QHeaderView.ResizeMode.Stretch)
        header.setStretchLastSection(False)"""
if old_header_resize in content:
    content = content.replace(old_header_resize, new_header_resize)
else:
    print("Could not find header resize.")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
