// lib/screens/nuevo_doc_screen.dart — Formulario de creación de Orden de Servicio
// desde la tablet directamente al servidor
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/api_service.dart';
import '../widgets/app_shell.dart';

class NuevoDocScreen extends StatefulWidget {
  const NuevoDocScreen({super.key});

  @override
  State<NuevoDocScreen> createState() => _NuevoDocScreenState();
}

class _NuevoDocScreenState extends State<NuevoDocScreen> {
  static const _red    = Color(0xFFC8102E);
  static const _border = Color(0xFFE5E7EB);
  static const _bg     = Color(0xFFF9FAFB);

  final _formKey = GlobalKey<FormState>();
  bool _loading    = false;
  bool _loadingCat = true;
  String? _error;

  // ── Listas de catálogo ───────────────────────────────────────────────────
  List<Map<String, dynamic>> _clientes     = [];
  List<Map<String, dynamic>> _tecnicos     = [];
  List<Map<String, dynamic>> _tiposServ    = [];
  List<Map<String, dynamic>> _tiposInst    = [];

  // ── Valores del formulario ───────────────────────────────────────────────
  String? _tipo        = 'Individual'; // Individual | Lote
  String? _modalidad   = 'Digital';    // Digital | Físico
  int?    _clienteId;
  int?    _tecnicoId;
  int?    _tipoServId;
  int?    _tipoInstId;
  final _observCtrl  = TextEditingController();
  final _cantidadCtrl = TextEditingController(text: '1'); // para lote

  @override
  void initState() {
    super.initState();
    _loadCatalogos();
  }

  @override
  void dispose() {
    _observCtrl.dispose();
    _cantidadCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCatalogos() async {
    try {
      final results = await Future.wait([
        ApiService.instance.getCatalogo('/api/v1/clientes'),
        ApiService.instance.getCatalogo('/api/v1/tecnicos'),
        ApiService.instance.getCatalogo('/api/v1/tipos-servicio'),
        ApiService.instance.getCatalogo('/api/v1/tipos-instrumento'),
      ]);
      if (mounted) setState(() {
        _clientes  = results[0];
        _tecnicos  = results[1];
        _tiposServ = results[2];
        _tiposInst = results[3];
        _loadingCat = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _loadingCat = false;
        _error = 'Error al cargar catálogos: $e';
      });
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _loading = true; _error = null; });

    try {
      final payload = {
        'tipo':             _tipo,
        'modalidad':        _modalidad,
        'id_cliente':       _clienteId,
        'id_tecnico':       _tecnicoId,
        'id_tipo_servicio': _tipoServId,
        'id_tipo_instrumento': _tipoInstId,
        'observaciones':    _observCtrl.text.trim(),
        if (_tipo == 'Lote')
          'cantidad': int.tryParse(_cantidadCtrl.text) ?? 1,
      };

      final result = await ApiService.instance.crearOrden(payload);
      if (mounted) {
        final folio = result['folio_os'] ?? result['folio'] ?? 'creada';
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            title: const Row(children: [
              Icon(Icons.check_circle, color: Colors.green, size: 24),
              SizedBox(width: 8),
              Text('Orden Creada', style: TextStyle(fontSize: 16)),
            ]),
            content: Column(mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('La orden fue creada exitosamente en el servidor.',
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  const Icon(Icons.assignment, color: _red, size: 20),
                  const SizedBox(width: 8),
                  Text('Folio: $folio',
                      style: const TextStyle(fontWeight: FontWeight.w800,
                          color: _red, fontSize: 14)),
                ]),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sincroniza el dashboard para ver la nueva orden.',
                style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ]),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: _red, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.pop(context);
                  context.pop(); // regresar al dashboard
                },
                child: const Text('Aceptar'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() {
        _error   = 'Error al crear la orden: $e';
        _loading = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      currentRoute: '/nuevo-doc',
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            // Header
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: _border)),
              ),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                      color: _red, borderRadius: BorderRadius.circular(8)),
                  child: const Icon(Icons.add_circle_outline,
                      color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Nueva Orden de Servicio',
                      style: TextStyle(color: Color(0xFF111827),
                          fontWeight: FontWeight.w800, fontSize: 17)),
                  Text('Completa el formulario para crear la orden',
                      style: TextStyle(color: Color(0xFF6B7280), fontSize: 11)),
                ])),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                  onPressed: () => context.pop(),
                ),
              ]),
            ),
            // Cuerpo
            Expanded(child: _loadingCat
                ? const Center(child: CircularProgressIndicator(color: _red))
                : _buildForm()),
          ]),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                border: Border.all(color: Colors.red.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_error!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
            ),
            const SizedBox(height: 16),
          ],

          // ── Tipo de documento ─────────────────────────────────────────────
          _SectionTitle('Tipo de Documento'),
          const SizedBox(height: 8),
          Row(children: [
            for (final t in ['Individual', 'Lote'])
              Expanded(child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _RadioCard(
                  label: t,
                  icon: t == 'Individual'
                      ? Icons.assignment_outlined
                      : Icons.layers_outlined,
                  selected: _tipo == t,
                  onTap: () => setState(() => _tipo = t),
                ),
              )),
          ]),
          if (_tipo == 'Lote') ...[
            const SizedBox(height: 12),
            _InputField(
              label: 'Cantidad de OS en el lote',
              controller: _cantidadCtrl,
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 2) {
                  return 'Mínimo 2 órdenes para un lote';
                }
                return null;
              },
            ),
          ],

          const SizedBox(height: 20),
          // ── Modalidad ────────────────────────────────────────────────────
          _SectionTitle('Modalidad'),
          const SizedBox(height: 8),
          Row(children: [
            for (final m in ['Digital', 'Físico'])
              Expanded(child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _RadioCard(
                  label: m,
                  icon: m == 'Digital'
                      ? Icons.computer_outlined
                      : Icons.print_outlined,
                  selected: _modalidad == m,
                  onTap: () => setState(() => _modalidad = m),
                ),
              )),
          ]),

          const SizedBox(height: 20),
          // ── Cliente ───────────────────────────────────────────────────────
          _SectionTitle('Cliente'),
          const SizedBox(height: 8),
          _CatalogDropdown(
            hint: 'Seleccionar cliente...',
            items: _clientes,
            labelKey: 'nombre',  // catalogos.py devuelve alias 'nombre' de razon_social
            idKey: 'id',
            value: _clienteId,
            onChanged: (v) => setState(() => _clienteId = v),
            validator: (v) => v == null ? 'Selecciona un cliente' : null,
          ),

          const SizedBox(height: 16),
          // ── Técnico ──────────────────────────────────────────────────────
          _SectionTitle('Técnico Asignado'),
          const SizedBox(height: 8),
          _CatalogDropdown(
            hint: 'Seleccionar técnico...',
            items: _tecnicos,
            labelKey: 'nombre_completo',
            idKey: 'id',
            value: _tecnicoId,
            onChanged: (v) => setState(() => _tecnicoId = v),
            validator: (v) => v == null ? 'Selecciona un técnico' : null,
          ),

          const SizedBox(height: 16),
          // ── Tipo de Servicio ──────────────────────────────────────────────
          _SectionTitle('Tipo de Servicio'),
          const SizedBox(height: 8),
          _CatalogDropdown(
            hint: 'Seleccionar tipo de servicio...',
            items: _tiposServ,
            labelKey: 'nombre',
            idKey: 'id',
            value: _tipoServId,
            onChanged: (v) => setState(() => _tipoServId = v),
            validator: (v) => v == null ? 'Selecciona el tipo de servicio' : null,
          ),

          const SizedBox(height: 16),
          // ── Tipo de Instrumento ───────────────────────────────────────────
          _SectionTitle('Tipo de Instrumento'),
          const SizedBox(height: 8),
          _CatalogDropdown(
            hint: 'Seleccionar tipo de instrumento...',
            items: _tiposInst,
            labelKey: 'nombre',
            idKey: 'id',
            value: _tipoInstId,
            onChanged: (v) => setState(() => _tipoInstId = v),
          ),

          const SizedBox(height: 16),
          // ── Observaciones ─────────────────────────────────────────────────
          _SectionTitle('Observaciones (opcional)'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _observCtrl,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Instrucciones especiales, notas, etc.',
              hintStyle: const TextStyle(fontSize: 12,
                  color: Color(0xFF9CA3AF)),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _red, width: 2)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),

          const SizedBox(height: 32),
          // ── Botón crear ───────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _loading ? Colors.grey.shade400 : _red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              onPressed: _loading ? null : _submit,
              icon: _loading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2,
                          color: Colors.white))
                  : const Icon(Icons.add_circle_outline, size: 20),
              label: Text(
                _loading ? 'Creando orden...' : 'Crear Orden de Servicio',
                style: const TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

// ── Widgets auxiliares ─────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
          color: Color(0xFF374151), letterSpacing: 0.4));
}

class _RadioCard extends StatelessWidget {
  final String   label;
  final IconData icon;
  final bool     selected;
  final VoidCallback onTap;
  const _RadioCard({required this.label, required this.icon,
      required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFC8102E);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFEE2E2) : Colors.white,
          border: Border.all(
              color: selected ? red : const Color(0xFFE5E7EB), width: 2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Icon(icon, size: 18,
              color: selected ? red : const Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Text(label, style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: selected ? red : const Color(0xFF374151))),
          const Spacer(),
          if (selected)
            const Icon(Icons.check_circle, size: 16, color: red),
        ]),
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  final String                label;
  final TextEditingController controller;
  final TextInputType?        keyboardType;
  final String? Function(String?)? validator;
  const _InputField({required this.label, required this.controller,
      this.keyboardType, this.validator});

  @override
  Widget build(BuildContext context) => TextFormField(
    controller: controller,
    keyboardType: keyboardType,
    validator: validator,
    decoration: InputDecoration(
      labelText: label,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFC8102E), width: 2)),
      filled: true,
      fillColor: Colors.white,
    ),
  );
}

class _CatalogDropdown extends StatelessWidget {
  final String                     hint;
  final List<Map<String, dynamic>> items;
  final String                     labelKey;
  final String                     idKey;
  final int?                       value;
  final ValueChanged<int?>         onChanged;
  final String? Function(int?)?    validator;
  const _CatalogDropdown({required this.hint, required this.items,
      required this.labelKey, required this.idKey,
      required this.value, required this.onChanged, this.validator});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      value: value,
      hint: Text(hint, style: const TextStyle(fontSize: 12,
          color: Color(0xFF9CA3AF))),
      validator: validator != null ? (v) => validator!(v) : null,
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(
                color: Color(0xFFC8102E), width: 2)),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 12),
      ),
      items: items.map((item) {
        final id    = item[idKey] as int? ?? 0;
        final label = item[labelKey] as String? ?? '—';
        return DropdownMenuItem<int>(
          value: id,
          child: Text(label,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: onChanged,
    );
  }
}
