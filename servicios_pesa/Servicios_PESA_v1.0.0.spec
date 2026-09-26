from PyInstaller.utils.hooks import collect_submodules

hidden_ui        = collect_submodules('ui')
hidden_services  = collect_submodules('services')
hidden_database  = collect_submodules('database')
hidden_auth      = collect_submodules('auth')
hidden_models    = collect_submodules('models')

all_hidden = sorted(list(set(
    hidden_ui + hidden_services + hidden_database + hidden_auth + hidden_models + [
        'ui',
        'ui.main_window',
        'ui.widgets',
        'ui.widgets.dashboard_widget',
        'ui.widgets.batch_generator_widget',
        'ui.widgets.os_form_widget',
        'ui.widgets.lp_form_widget',
        'ui.widgets.lv_form_widget',
        'ui.widgets.recepcion_widget',
        'ui.widgets.scanner_widget',
        'ui.widgets.catalogos_widget',
        'ui.widgets.configuracion_widget',
        'ui.widgets.pruebas_metrologicas',
        'ui.widgets.equipo_search_widget',
        'ui.widgets.re_form_widget',
        'ui.widgets.rma_form_widget',
        'ui.dialogs',
        'ui.dialogs.digital_service_dialog',
        'ui.dialogs.login_dialog',
        'ui.dialogs.modo_formato_dialog',
        'ui.dialogs.toma_digital_dialog',
        'services',
        'services.batch_pdf_generator',
        'services.folio_service',
        'services.lp_pdf_generator',
        'services.lv_pdf_generator',
        'services.metrology',
        'services.os_pdf_generator',
        'services.pdf_generator',
        'services.pdf_router',
        'services.pdf_service',
        'services.re_pdf_generator',
        'services.rma_pdf_generator',
        'services.scanner_service',
        'services.tipo_servicio_rules',
        'database',
        'database.connection',
        'auth',
        'auth.session_context',
        'sync_manager',
        'psycopg2',
        'psycopg2_binary',
        'bcrypt',
        'reportlab',
        'PIL',
    ]
)))

a = Analysis(
    ['main.py'],
    pathex=['.'],
    binaries=[],
    datas=[
        ('Img', 'Img'),
        ('ui', 'ui'),
        ('services', 'services'),
        ('database', 'database'),
        ('auth', 'auth'),
        ('models', 'models'),
    ],
    hiddenimports=all_hidden,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='Servicios_PESA_v1.0.0',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['Img\\logo_pesa.png'],
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='Servicios_PESA_v1.0.0',
)
