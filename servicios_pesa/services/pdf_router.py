"""
pdf_router.py - Enrutador centralizado de generacion de PDFs.

Regla de oro:
  La BD es la fuente unica de verdad.
  Cada vez que se edita/guarda un registro, el PDF debe regenerarse
  con force=True para sobreescribir la version anterior en disco.

Ruteo por prefijo de folio:
  OS-*   -> os_pdf_generator.OsPdfGenerator
  LP-*   -> lp_pdf_generator.LPPdfGenerator
  RMA-*  -> rma_pdf_generator.RmaPdfGenerator
  RE-*   -> re_pdf_generator.RePdfGenerator
"""
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


def _get_output_path(folio: str, subfolder: str = "PDF_OS") -> str:
    """
    Retorna la ruta de salida estandar para un PDF de folio dado.
    Intenta primero el servidor centralizado; si no tiene permisos,
    cae a la carpeta local del usuario.
    """
    import sys
    if sys.platform == "win32":
        server_dir = Path(r"C:\PesaServidorCentral") / subfolder
        try:
            server_dir.mkdir(parents=True, exist_ok=True)
            return str(server_dir / f"{folio}.pdf")
        except (PermissionError, OSError):
            pass
    # macOS / Linux (o Windows sin permisos): carpeta local del usuario.
    # Antes se creaba una carpeta literal "C:\PesaServidorCentral" en el CWD.
    local_dir = Path.home() / "PesaServidorLocal" / subfolder
    local_dir.mkdir(parents=True, exist_ok=True)
    return str(local_dir / f"{folio}.pdf")


def _actualizar_bd_pdf(os_id: int, pdf_path: str) -> None:
    """Actualiza pdf_path, pdf_b64 y marca pdf_generado=True en la base de datos."""
    try:
        import base64
        from models.orden_servicio import orden_servicio_repo
        with open(pdf_path, "rb") as fh:
            b64 = base64.b64encode(fh.read()).decode("ascii")
        orden_servicio_repo._write(
            """
            UPDATE ordenes_servicio
            SET pdf_path     = %s,
                pdf_b64      = %s,
                pdf_generado = TRUE,
                updated_at   = NOW()
            WHERE id = %s
            """,
            (pdf_path, b64, os_id),
            returning=False,
        )
    except Exception as exc:
        logger.debug("No se pudo actualizar pdf_b64 en BD para os_id=%s: %s", os_id, exc)


def _reestampar_firma_en_pdf(os_data: dict, output_path: str) -> Optional[str]:
    """
    Reestampa la firma oficial de perfil del técnico directamente sobre un PDF
    existente en pdf_b64 (típico de órdenes completadas en tablet).
    Preserva intactos todos los datos metrológicos y números de la orden.
    """
    import base64
    import io
    import os as _os
    import zlib
    from PIL import Image
    from pypdf import PdfReader, PdfWriter
    from pypdf.generic import NameObject, NumberObject
    from services.os_pdf_generator import _firma_perfil_tecnico, _limpiar_b64_firma

    firma_b64 = _firma_perfil_tecnico(os_data) or _limpiar_b64_firma(os_data.get("firma_tecnico"))
    if not firma_b64:
        return None

    pdf_raw = os_data.get("pdf_b64")
    if not pdf_raw:
        return None

    try:
        pdf_bytes = base64.b64decode(pdf_raw)
        reader = PdfReader(io.BytesIO(pdf_bytes))
        if not reader.pages:
            return None
        writer = PdfWriter(clone_from=reader)
        page = writer.pages[0]
        xobjects = page["/Resources"].get("/XObject", {})

        target_obj = None
        min_area = float("inf")
        for _name, xobj_ref in xobjects.items():
            obj = xobj_ref.get_object()
            if obj.get("/Subtype") == "/Image":
                w = int(obj.get("/Width", 0))
                h = int(obj.get("/Height", 0))
                if 120 <= w <= 1400 and 30 <= h <= 350 and (w / max(1, h)) > 1.4:
                    area = w * h
                    if area < min_area:
                        min_area = area
                        target_obj = obj

        if not target_obj:
            return None

        ow, oh = int(target_obj["/Width"]), int(target_obj["/Height"])
        aspect = ow / max(1, oh)

        raw_img = firma_b64.split(",")[-1].strip()
        img_bytes = base64.b64decode(raw_img)
        firma = Image.open(io.BytesIO(img_bytes)).convert("RGBA")
        bbox = firma.getbbox()
        if bbox:
            firma = firma.crop(bbox)
        fw, fh = firma.size

        if fw / max(1, fh) >= aspect:
            cw, ch = fw, max(1, round(fw / aspect))
        else:
            cw, ch = max(1, round(fh * aspect)), fh
        pad = 4
        cw, ch = cw + 2 * pad, max(1, round((cw + 2 * pad) / aspect))
        canvas = Image.new("RGBA", (cw, ch), (255, 255, 255, 0))
        canvas.paste(firma, ((cw - fw) // 2, (ch - fh) // 2), firma)

        rgb = canvas.convert("RGB").tobytes()
        alpha = canvas.getchannel("A").tobytes()

        def _reemplazar(stream_obj, raw, colorspace):
            stream_obj._data = zlib.compress(raw)
            stream_obj[NameObject("/Filter")] = NameObject("/FlateDecode")
            stream_obj[NameObject("/Width")] = NumberObject(cw)
            stream_obj[NameObject("/Height")] = NumberObject(ch)
            stream_obj[NameObject("/BitsPerComponent")] = NumberObject(8)
            stream_obj[NameObject("/ColorSpace")] = NameObject(colorspace)
            for k in ("/DecodeParms", "/Length"):
                if k in stream_obj:
                    del stream_obj[k]

        _reemplazar(target_obj, rgb, "/DeviceRGB")
        if "/SMask" in target_obj:
            smask = target_obj["/SMask"].get_object()
            _reemplazar(smask, alpha, "/DeviceGray")

        tmp_path = f"{output_path}.tmp"
        with open(tmp_path, "wb") as f_out:
            writer.write(f_out)
        _os.replace(tmp_path, output_path)
        logger.info("Firma oficial reestampada en PDF existente: %s", output_path)
        return output_path
    except Exception as exc:
        logger.warning("Fallo al reestampar firma en PDF existente: %s", exc)
        return None


def regenerar_pdf(os_id: int, folio: str, force: bool = True) -> Optional[str]:
    """
    Regenera el PDF de un registro completo, enrutando al generador correcto
    segun el prefijo del folio.

    Args:
        os_id:  ID del registro en ordenes_servicio.
        folio:  Folio completo (ej. "OS-26-385", "LP-26-12", "RMA-26-7").
        force:  Si True (default), sobreescribe aunque el PDF ya exista.
                Debe ser True siempre que se llame despues de un UPDATE.

    Returns:
        Ruta absoluta del PDF generado, o None si ocurrio un error.
    """
    if not folio:
        logger.warning("regenerar_pdf: folio vacio para os_id=%s", os_id)
        return None

    try:
        from models.orden_servicio import orden_servicio_repo

        os_data = orden_servicio_repo.get_by_id(os_id)
        if not os_data:
            logger.error("regenerar_pdf: no se encontro os_id=%s en BD", os_id)
            return None

        folio_upper = folio.upper()

        # LP -- Levantamiento de Proyecto
        if folio_upper.startswith("LP-"):
            from services.lp_pdf_generator import LPPdfGenerator
            output_path = _get_output_path(folio, "PDF_OS")
            gen = LPPdfGenerator()
            return gen.generate(os_data=os_data, output_path=output_path, force=force)

        # RMA -- Remision
        elif folio_upper.startswith("RMA-"):
            try:
                from services.rma_pdf_generator import RmaPdfGenerator
                output_path = _get_output_path(folio, "PDF_OS")
                gen = RmaPdfGenerator()
                return gen.generate(os_data=os_data, output_path=output_path, force=force)
            except (ImportError, AttributeError) as exc:
                logger.warning("RmaPdfGenerator no disponible: %s", exc)
                return None

        # RE -- Revision / Estructuras
        elif folio_upper.startswith("RE-"):
            try:
                from services.re_pdf_generator import RePdfGenerator
                output_path = _get_output_path(folio, "PDF_OS")
                gen = RePdfGenerator()
                return gen.generate(os_data=os_data, output_path=output_path, force=force)
            except (ImportError, AttributeError) as exc:
                logger.warning("RePdfGenerator no disponible: %s", exc)
                return None

        # LV -- Levantamiento Metrologico y Logistica de Pesas
        elif folio_upper.startswith("LV-"):
            try:
                from services.lv_pdf_generator import LvPdfGenerator
                output_path = _get_output_path(folio, "PDF_OS")
                gen = LvPdfGenerator()
                return gen.generate(os_data=os_data, output_path=output_path, force=force)
            except (ImportError, AttributeError) as exc:
                logger.warning("LvPdfGenerator no disponible: %s", exc)
                return None

        # OS -- Orden de Servicio Metrologica (default)
        else:
            from services.os_pdf_generator import os_pdf_generator
            rep  = orden_servicio_repo.get_repetibilidad(os_id)
            exc  = orden_servicio_repo.get_excentricidad(os_id)
            exac = orden_servicio_repo.get_exactitud(os_id)

            # Nombre del tecnico desde os_data (ya viene en v_ordenes_servicio)
            tecnico_nombre = (
                os_data.get("tecnico_nombre")
                or os_data.get("tecnico")
                or None
            )

            # Inyectar dirección de sucursal/planta si la vista aún no la expone.
            # Se consulta cliente_sucursales directamente usando sucursal_id de la OS.
            if not os_data.get("sucursal_direccion") and not os_data.get("direccion_cliente"):
                try:
                    suc_id_row = orden_servicio_repo._fetch_one(
                        "SELECT sucursal_id FROM ordenes_servicio WHERE id = %s",
                        (os_id,)
                    )
                    suc_id = (suc_id_row or {}).get("sucursal_id")
                    if suc_id:
                        suc_row = orden_servicio_repo._fetch_one(
                            "SELECT direccion FROM cliente_sucursales WHERE id = %s",
                            (suc_id,)
                        )
                        if suc_row and suc_row.get("direccion"):
                            os_data["sucursal_direccion"] = suc_row["direccion"]
                            os_data["direccion"]           = suc_row["direccion"]
                except Exception as suc_exc:
                    logger.debug("No se pudo enriquecer sucursal_direccion: %s", suc_exc)

            # Inyectar tipo_instrumento desde la tabla si la vista lo expone como NULL.
            # Ocurre con OS antiguas donde la columna existía pero el JOIN devuelve NULL.
            if not os_data.get("tipo_instrumento"):
                try:
                    ti_row = orden_servicio_repo._fetch_one(
                        """
                        SELECT ti.nombre AS tipo_instrumento
                        FROM ordenes_servicio os
                        LEFT JOIN cat_tipo_instrumento ti ON os.id_tipo_instrumento = ti.id
                        WHERE os.id = %s
                        """,
                        (os_id,)
                    )
                    if ti_row and ti_row.get("tipo_instrumento"):
                        os_data["tipo_instrumento"] = ti_row["tipo_instrumento"]
                except Exception as ti_exc:
                    logger.debug("No se pudo enriquecer tipo_instrumento: %s", ti_exc)

            output_path = _get_output_path(folio, "PDF_OS")

            # Caso especial: orden digital de la tablet con lecturas completas en pdf_b64
            # pero sin filas normalizadas en det_repetibilidad/det_exactitud.
            # Reestampamos la firma oficial del perfil del técnico manteniendo
            # 100% intactas todas las lecturas y datos metrológicos del documento original.
            res_pdf = None
            if not rep and not exc and not exac and os_data.get("pdf_b64"):
                res_pdf = _reestampar_firma_en_pdf(os_data, output_path)

            if not res_pdf:
                res_pdf = os_pdf_generator.generate_os_pdf(
                    os_data=os_data,
                    repetibilidad=rep,
                    excentricidad=exc,
                    exactitud=exac,
                    output_path=output_path,
                    tecnico_nombre=tecnico_nombre,
                    force=force,
                )

            if res_pdf and Path(res_pdf).exists():
                _actualizar_bd_pdf(os_id, res_pdf)

            return res_pdf

    except Exception as exc:
        logger.exception(
            "regenerar_pdf: error para folio=%s os_id=%s: %s", folio, os_id, exc
        )
        return None


def regenerar_pdf_orden(folio: str, force: bool = True) -> Optional[str]:
    """
    Regenera el PDF de una orden a partir de su FOLIO.

    Con force=True invalida el PDF existente y lo vuelve a renderizar desde
    los datos metrológicos en BD y la firma OFICIAL registrada del técnico
    asignado (cat_tecnicos.firma_digital). El archivo se sobrescribe con el
    mismo nombre: {folio}.pdf.

    Returns:
        Ruta absoluta del PDF regenerado, o None si no existe la orden o falló.
    """
    folio = (folio or "").strip()
    if not folio:
        return None
    from models.orden_servicio import orden_servicio_repo

    row = orden_servicio_repo._fetch_one(
        "SELECT id FROM ordenes_servicio WHERE folio_os = %s", (folio,)
    )
    if not row:
        logger.error("regenerar_pdf_orden: folio %s no existe en BD", folio)
        return None
    return regenerar_pdf(int(row["id"]), folio, force=force)


def abrir_pdf(os_id: int, folio: str) -> Optional[str]:
    """
    Abre el PDF de la OS con el visor del sistema.

    Regla de oro (anti-sobreescritura):
      1. Leer pdf_path guardado en BD → si el archivo existe en disco → abrir directamente.
      2. Buscar el PDF en las carpetas predeterminadas por folio → si existe → abrir directamente.
      3. Solo si NINGUNA ruta produce un archivo físico → regenerar (force=True).

    NUNCA sobreescribe un PDF existente al abrir desde el Dashboard.

    Returns:
        Ruta del PDF abierto, o None si no se pudo abrir.
    """
    import os
    import subprocess
    import sys

    def _open_file(path: str) -> str:
        """Abre el archivo con el visor predeterminado del S.O."""
        if sys.platform == "win32":
            os.startfile(path)
        elif sys.platform == "darwin":
            subprocess.run(["open", path], check=False)
        else:
            subprocess.run(["xdg-open", path], check=False)
        return path

    # ── 1. Leer pdf_path registrado en la BD ─────────────────────────────────
    try:
        from models.orden_servicio import orden_servicio_repo
        os_row = orden_servicio_repo._fetch_one(
            "SELECT pdf_path, datos_tecnicos_json FROM ordenes_servicio WHERE id = %s",
            (os_id,)
        )
        bd_pdf_path = (os_row or {}).get("pdf_path") if os_row else None
        if bd_pdf_path and Path(bd_pdf_path).exists():
            logger.info("abrir_pdf: usando pdf_path de BD para folio=%s → %s", folio, bd_pdf_path)
            return _open_file(bd_pdf_path)
    except Exception as exc_bd:
        logger.debug("abrir_pdf: no se pudo leer pdf_path de BD: %s", exc_bd)

    # ── 2. Buscar en carpetas predeterminadas por folio ───────────────────────
    _PDF_DIRS = [
        Path(r"C:\PesaServidorCentral\PDF_OS"),
        Path.home() / "PesaServidorLocal" / "PDF_OS",
    ]
    for pdf_dir in _PDF_DIRS:
        candidate = pdf_dir / f"{folio}.pdf"
        if candidate.exists():
            logger.info("abrir_pdf: PDF encontrado en carpeta predeterminada: %s", candidate)
            # Registrar en BD para la próxima vez
            try:
                from models.orden_servicio import orden_servicio_repo
                orden_servicio_repo.update_pdf_path(os_id, str(candidate))
            except Exception:
                pass
            return _open_file(str(candidate))

    # ── 3. El archivo no existe en ninguna ruta → regenerar ───────────────────
    logger.info(
        "abrir_pdf: PDF no encontrado en disco para folio=%s → regenerando", folio
    )
    pdf_path = regenerar_pdf(os_id, folio, force=True)

    if not pdf_path or not Path(pdf_path).exists():
        logger.warning("abrir_pdf: no se pudo obtener PDF para folio=%s", folio)
        return None

    # Persistir la ruta recién generada
    try:
        from models.orden_servicio import orden_servicio_repo
        orden_servicio_repo.update_pdf_path(os_id, pdf_path)
    except Exception:
        pass

    try:
        return _open_file(pdf_path)
    except Exception as exc:
        logger.error("abrir_pdf: error al abrir '%s': %s", pdf_path, exc)
        return None
