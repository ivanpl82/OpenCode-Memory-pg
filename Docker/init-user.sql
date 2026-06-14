-- 1. Crear la base de datos específica para la aplicación
CREATE DATABASE contexto;

-- 2. Crear el usuario de la aplicación con su propia contraseña
CREATE USER __APP_USER__ WITH PASSWORD '__APP_PASSWORD__';

-- 3. Conceder acceso a la base de datos específica
GRANT CONNECT ON DATABASE contexto TO __APP_USER__;

-- 4. Revocar permisos de creación en el esquema público para todos los usuarios
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- 5. Cambiar al contexto de la nueva base de datos para configurar los permisos específicos
\c contexto

-- 6. Crear un esquema propio para el usuario de la aplicación y hacerlo propietario
CREATE SCHEMA __APP_USER___schema AUTHORIZATION __APP_USER__;

-- 7. Otorgar al usuario todos los privilegios sobre su esquema
GRANT ALL ON SCHEMA __APP_USER___schema TO __APP_USER__;

-- 8. Establecer el esquema como el predeterminado para el usuario
ALTER USER __APP_USER__ SET search_path TO __APP_USER___schema, public;

-- 9. Instalar la extensión pgvector en la base de datos de la aplicación
CREATE EXTENSION IF NOT EXISTS vector;

-- 10. Otorgar al usuario permiso para usar la extensión en el esquema público
GRANT USAGE ON SCHEMA public TO __APP_USER__;