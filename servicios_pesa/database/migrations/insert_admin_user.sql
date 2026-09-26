-- =============================================================================
-- SERVICIOS PESA v2.0 — Script de inicialización del usuario Administrador
-- =============================================================================
-- REQUISITO: la extensión pgcrypto debe estar habilitada en la BD.
--            Si no lo está, ejecuta primero:
--            CREATE EXTENSION IF NOT EXISTS pgcrypto;
--
-- MÉTODO DE HASH: bcrypt via pgcrypto crypt()  ← mismo que usa la app
--   gen_salt('bf', 10) = bcrypt con cost factor 10 (recomendado para 2026)
--
-- USUARIO:     ivancolin1207
-- CONTRASEÑA:  131019  (almacenada como hash bcrypt, nunca en texto plano)
-- ROL:         admin
-- =============================================================================

-- 1. Habilitar pgcrypto (idempotente)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. Asegurar que el rol 'admin' exista
INSERT INTO roles (nombre, descripcion)
VALUES ('admin', 'Acceso total al sistema')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO roles (nombre, descripcion) VALUES ('logistica',  'Creación de OS, RMA y RE')      ON CONFLICT (nombre) DO NOTHING;
INSERT INTO roles (nombre, descripcion) VALUES ('servicio',   'Técnico de campo — tablet')      ON CONFLICT (nombre) DO NOTHING;
INSERT INTO roles (nombre, descripcion) VALUES ('recepcion',  'Control de entrega de expedientes') ON CONFLICT (nombre) DO NOTHING;

-- 3. Insertar / actualizar el usuario administrador principal
--
--    crypt('131019', gen_salt('bf', 10))  →  genera un hash bcrypt nuevo
--    La app verifica con:
--        WHERE password_hash = crypt(<contraseña_ingresada>, password_hash)
--
INSERT INTO usuarios (
    username,
    nombre_completo,
    id_rol,
    password_hash,
    activo,
    created_at
)
VALUES (
    'ivancolin1207',
    'Iván Colín',
    (SELECT id FROM roles WHERE nombre = 'admin'),
    crypt('131019', gen_salt('bf', 10)),
    TRUE,
    NOW()
)
ON CONFLICT (username) DO UPDATE SET
    nombre_completo = EXCLUDED.nombre_completo,
    id_rol          = EXCLUDED.id_rol,
    password_hash   = crypt('131019', gen_salt('bf', 10)),
    activo          = TRUE;

-- 4. Verificar que el usuario quedó correctamente insertado
SELECT
    u.id,
    u.username,
    u.nombre_completo,
    r.nombre  AS rol,
    u.activo,
    -- Prueba de verificación: debe retornar TRUE si la contraseña es correcta
    (u.password_hash = crypt('131019', u.password_hash)) AS pass_ok
FROM usuarios u
JOIN roles r ON u.id_rol = r.id
WHERE u.username = 'ivancolin1207';

-- =============================================================================
-- USUARIOS DE DEMO ADICIONALES (opcionales — útiles para pruebas)
-- =============================================================================
/*
INSERT INTO usuarios (username, nombre_completo, id_rol, password_hash, activo)
VALUES
    ('admin',         'Administrador General',         (SELECT id FROM roles WHERE nombre='admin'),     crypt('admin',  gen_salt('bf',10)), TRUE),
    ('logistica',     'Usuario Logística Demo',        (SELECT id FROM roles WHERE nombre='logistica'), crypt('pesa',   gen_salt('bf',10)), TRUE),
    ('luis.fernando', 'Luis Fernando Guerrero Arroyo', (SELECT id FROM roles WHERE nombre='servicio'),  crypt('pesa',   gen_salt('bf',10)), TRUE),
    ('recepcion',     'Recepción Demo',                (SELECT id FROM roles WHERE nombre='recepcion'), crypt('pesa',   gen_salt('bf',10)), TRUE)
ON CONFLICT (username) DO NOTHING;
*/

-- =============================================================================
-- CÓMO CAMBIAR LA CONTRASEÑA DE UN USUARIO
-- =============================================================================
-- UPDATE usuarios
-- SET password_hash = crypt('nueva_contraseña', gen_salt('bf', 10))
-- WHERE username = 'ivancolin1207';

-- =============================================================================
-- CÓMO VERIFICAR MANUALMENTE UNA CONTRASEÑA DESDE PSQL
-- =============================================================================
-- SELECT (password_hash = crypt('131019', password_hash)) AS es_correcta
-- FROM usuarios WHERE username = 'ivancolin1207';
