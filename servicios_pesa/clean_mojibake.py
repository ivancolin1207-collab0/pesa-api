import re

path = 'ui/widgets/dashboard_widget.py'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Fix SyncCheckDelegate mojibake
content = content.replace('âœ“âœ“', '✓✓')
content = content.replace('âœ“', '✓')
content = content.replace('â€”', '—')
content = content.replace('AdministraciÃ³n', 'Administración')
content = content.replace('FÃ­sicos', 'Físicos')
content = content.replace('fÃ­sic', 'físic')
content = content.replace('SelecciÃ³n', 'Selección')
content = content.replace('Ã³', 'ó')
content = content.replace('Ã¡', 'á')
content = content.replace('Ã©', 'é')
content = content.replace('Ã­', 'í')
content = content.replace('Ãº', 'ú')

# Replace buttons that start with any bad chars like "Y  Actualizar"
content = re.sub(r'QPushButton\(".*?(Actualizar|Sincronizar|PDF|Descargar|Rehacer|Capturar).*?"\)', r'QPushButton("\1")', content)

content = re.sub(r'QPushButton\(".*?Descargar Selección \(\.zip \/ \.rar\)"\)', 'QPushButton("Descargar Selección (.zip / .rar)")', content)
content = re.sub(r'setText\(".*?Descargar Selección \(\.zip \/ \.rar\)"\)', 'setText("Descargar Selección (.zip / .rar)")', content)
content = re.sub(r'setText\(f".*?Descargar Selección \(', 'setText(f"Descargar Selección (', content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
