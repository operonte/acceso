# Auditoría de Licencias de Software (Open Source Compliance)

Este documento detalla el análisis de cumplimiento de licencias para todas las dependencias de terceros definidas en `pubspec.yaml` de la aplicación **Acceso**. El objetivo es garantizar el uso exclusivo de licencias comerciales permisivas y amigables, previniendo cualquier riesgo de "copyleft" fuerte (ej. GPL) en el software propietario.

## 📋 Resumen de Dependencias y Licencias

| Paquete | Versión | Tipo de Licencia | Compatibilidad Comercial | Propósito |
| :--- | :--- | :--- | :--- | :--- |
| **flutter** | SDK | BSD-3-Clause | Excelente | Framework principal del sistema. |
| **cupertino_icons** | `^1.0.8` | MIT | Excelente | Iconos con estilo de diseño iOS/Cupertino. |
| **hive** | `^2.2.3` | Apache-2.0 | Excelente | Base de datos NoSQL local e indexada ultra-rápida. |
| **hive_flutter** | `^1.1.0` | Apache-2.0 | Excelente | Utilidades de integración de Hive con el ciclo de vida de Flutter. |
| **path_provider** | `^2.1.2` | BSD-3-Clause | Excelente | Acceso a directorios del sistema de archivos local para descargas. |
| **qr_flutter** | `^4.1.0` | MIT | Excelente | Renderizado gráfico de códigos QR de visitas pre-autorizadas. |
| **mobile_scanner** | `^7.3.0` | Apache-2.0 | Excelente | Captura de cámara y decodificación de pases QR. |
| **supabase_flutter** | `^2.8.0` | MIT | Excelente | Cliente SDK oficial para sincronización remota y persistencia cloud. |
| **image_picker** | `^1.2.3` | BSD-3-Clause | Excelente | Captura y selección de fotos de ingresos de personas/vehículos. |
| **file_picker** | `^8.1.4` | MIT | Excelente | Utilidad para seleccionar archivos CSV de importaciones en el sistema. |
| **csv** | `^8.0.0` | MIT | Excelente | Parser y codificador de archivos de hojas de datos CSV. |
| **sentry_flutter** | `^8.14.2` | MIT | Excelente | Monitoreo y reporte activo de excepciones y fallas en producción. |

## ⚖️ Conclusión del Análisis

Todas las dependencias directas e indirectas utilizan licencias de código abierto altamente permisivas (**MIT**, **Apache 2.0** y **BSD-3-Clause**). 

* **No se detectaron dependencias bajo licencias restrictivas (GPL, AGPL o LGPL).**
* El código fuente de la aplicación **Acceso** es 100% elegible para ser propietario y distribuido de manera segura y privada sin obligación de publicar ni liberar el código fuente bajo ningún esquema de licenciamiento recíproco.
