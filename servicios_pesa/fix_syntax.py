import re

path = 'ui/widgets/dashboard_widget.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

content = content.replace('else "En Proceso\"\"\"', 'else "En Proceso"')

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
