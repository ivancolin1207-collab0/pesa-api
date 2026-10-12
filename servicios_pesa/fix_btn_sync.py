import re
import io

path = 'ui/widgets/dashboard_widget.py'
with io.open(path, 'r', encoding='utf-8') as f:
    content = f.read()

old_btn_sync = """        btn_sync_header = QPushButton("Sincronizar")
        btn_sync_header.setObjectName("btn_sync_header")"""

new_btn_sync = """        btn_sync_header = QPushButton("Sincronizar")
        btn_sync_header.setObjectName("btn_sync_header")
        self._btn_sync = btn_sync_header
        self.btn_sincronizar = btn_sync_header
        self.btn_sync = btn_sync_header"""

if old_btn_sync in content:
    content = content.replace(old_btn_sync, new_btn_sync)
else:
    print("Could not find the button instantiation.")

# Also protect access in all places just in case
def protect_btn_sync(match):
    return f"""
        btn = getattr(self, '_btn_sync', None) or getattr(self, 'btn_sincronizar', None) or getattr(self, 'btn_sync', None)
        if btn:
            btn.{match.group(1)}
"""

content = re.sub(r'self\._btn_sync\.(setEnabled\([^\)]+\)|setText\([^\)]+\))', protect_btn_sync, content)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Modifications applied successfully.")
