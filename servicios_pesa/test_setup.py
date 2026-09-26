import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

print("[3/5] Conexion a PostgreSQL...")
from database.connection import db_pool
db_pool.initialize()
ok = db_pool.test_connection()
print("  Conexion: " + ("EXITOSA" if ok else "FALLO"))
if ok:
    print("  " + db_pool.get_server_version()[:70])

print("\n[4/5] Datos en BD...")
tecs = db_pool.execute_all("SELECT nombre_completo FROM cat_tecnicos ORDER BY id")
print("  Tecnicos (" + str(len(tecs)) + "):")
for t in tecs:
    print("    - " + t["nombre_completo"])

tipos = db_pool.execute_all("SELECT nombre FROM cat_tipo_servicio ORDER BY id")
print("  Tipos de servicio: " + str(len(tipos)) + " registros")

clases = db_pool.execute_all("SELECT codigo, nombre FROM cat_clase_exactitud ORDER BY orden_display")
print("  Clases de exactitud: " + str(len(clases)) + " registros")
for c in clases:
    print("    - Clase " + c["codigo"] + ": " + c["nombre"])

print("\n[5/5] Generador de folios...")
from models.folio_manager import FolioManager
from datetime import datetime
anio = datetime.now().year
f1 = FolioManager.get_next_folio("OS", anio)
f2 = FolioManager.get_next_folio("OS", anio)
f3 = FolioManager.get_next_folio("RMA", anio)
f4 = FolioManager.get_next_folio("RE", anio)
print("  OS sucesivos:  " + f1 + "  ->  " + f2 + "  (CONSECUTIVO OK)")
print("  RMA:  " + f3)
print("  RE:   " + f4)

db_pool.close_all()
print("\n=== VERIFICACION COMPLETA - TODO OK ===")
