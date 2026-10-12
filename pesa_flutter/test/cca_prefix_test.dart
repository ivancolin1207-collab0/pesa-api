import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class CcaDvePrefixFormatter extends TextInputFormatter {
  final String defaultPrefix;

  CcaDvePrefixFormatter({required this.defaultPrefix});

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final matchOld = RegExp(r'^(CCA|DVE)\.\d{2}\.').firstMatch(oldValue.text);
    final matchNew = RegExp(r'^(CCA|DVE)\.\d{2}\.').firstMatch(newValue.text);

    String prefix = defaultPrefix;
    if (matchOld != null) {
      prefix = matchOld.group(0)!;
    } else if (matchNew != null) {
      prefix = matchNew.group(0)!;
    }

    if (newValue.text.isEmpty) {
      return TextEditingValue(
        text: prefix,
        selection: TextSelection.collapsed(offset: prefix.length),
      );
    }

    if (newValue.text.startsWith(prefix)) {
      if (newValue.selection.baseOffset < prefix.length) {
        return newValue.copyWith(
          selection: TextSelection.collapsed(offset: prefix.length),
        );
      }
      return newValue;
    }

    String cleanContent = newValue.text.toUpperCase();
    if (cleanContent.startsWith('CCA') || cleanContent.startsWith('DVE')) {
      cleanContent = cleanContent.replaceFirst(RegExp(r'^(CCA|DVE)(\.\d{0,2})?\.?'), '');
    }
    if (cleanContent.isEmpty) {
      if (oldValue.text.startsWith(prefix) &&
          oldValue.text.length > prefix.length &&
          oldValue.selection.baseOffset > prefix.length) {
        cleanContent = oldValue.text.substring(prefix.length);
      }
    }

    final newText = '$prefix$cleanContent';
    final offset = (newValue.selection.baseOffset < prefix.length)
        ? prefix.length
        : (newValue.selection.baseOffset > newText.length ? newText.length : newValue.selection.baseOffset);

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}

void main() {
  group('CcaDvePrefixFormatter Tests', () {
    final formatter = CcaDvePrefixFormatter(defaultPrefix: 'CCA.26.');

    test('Initial typing with prefix', () {
      const oldValue = TextEditingValue(text: 'CCA.26.', selection: TextSelection.collapsed(offset: 7));
      const newValue = TextEditingValue(text: 'CCA.26.0', selection: TextSelection.collapsed(offset: 8));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.0');
      expect(res.selection.baseOffset, 8);
    });

    test('Deleting digit at end', () {
      const oldValue = TextEditingValue(text: 'CCA.26.01659', selection: TextSelection.collapsed(offset: 12));
      const newValue = TextEditingValue(text: 'CCA.26.0165', selection: TextSelection.collapsed(offset: 11));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.0165');
      expect(res.selection.baseOffset, 11);
    });

    test('User tries to backspace into prefix (deleting the dot)', () {
      const oldValue = TextEditingValue(text: 'CCA.26.', selection: TextSelection.collapsed(offset: 7));
      const newValue = TextEditingValue(text: 'CCA.26', selection: TextSelection.collapsed(offset: 6));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.');
      expect(res.selection.baseOffset, 7);
    });

    test('User selects all and deletes', () {
      const oldValue = TextEditingValue(text: 'CCA.26.01659', selection: TextSelection.collapsed(offset: 12));
      const newValue = TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.');
      expect(res.selection.baseOffset, 7);
    });

    test('User selects all and types 01659', () {
      const oldValue = TextEditingValue(text: 'CCA.26.', selection: TextSelection.collapsed(offset: 7));
      const newValue = TextEditingValue(text: '01659', selection: TextSelection.collapsed(offset: 5));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.01659');
    });

    test('User pastes lowercase cca.26.01659', () {
      const oldValue = TextEditingValue(text: 'CCA.26.', selection: TextSelection.collapsed(offset: 7));
      const newValue = TextEditingValue(text: 'cca.26.01659', selection: TextSelection.collapsed(offset: 12));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.26.01659');
    });

    test('DVE prefix formatter works for DVE orders', () {
      final dveFormatter = CcaDvePrefixFormatter(defaultPrefix: 'DVE.26.');
      const oldValue = TextEditingValue(text: 'DVE.26.', selection: TextSelection.collapsed(offset: 7));
      const newValue = TextEditingValue(text: 'DVE.26.5', selection: TextSelection.collapsed(offset: 8));
      final res = dveFormatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'DVE.26.5');
      expect(res.selection.baseOffset, 8);
    });

    test('Preserves existing previous year prefix like CCA.25.', () {
      const oldValue = TextEditingValue(text: 'CCA.25.001', selection: TextSelection.collapsed(offset: 10));
      const newValue = TextEditingValue(text: 'CCA.25.0012', selection: TextSelection.collapsed(offset: 11));
      final res = formatter.formatEditUpdate(oldValue, newValue);
      expect(res.text, 'CCA.25.0012');
    });
  });
}
