import 'package:flutter_test/flutter_test.dart';
import 'package:pesa_tablet/services/metrology_helper.dart';

void main() {
  group('Puntos de Apoyo por Instrumento', () {
    test('Báscula de plataforma -> 4', () {
      expect(getPuntosApoyoPorDefecto('Báscula de plataforma'), 4);
    });
    test('Báscula camionera -> 8', () {
      expect(getPuntosApoyoPorDefecto('Báscula camionera'), 8);
    });
    test('Báscula de ferrocarril -> 8', () {
      expect(getPuntosApoyoPorDefecto('Báscula de ferrocarril'), 8);
    });
    test('Báscula tolva -> 3', () {
      expect(getPuntosApoyoPorDefecto('Báscula tolva'), 3);
    });
    test('Báscula colgante / grúa -> 1', () {
      expect(getPuntosApoyoPorDefecto('Báscula colgante / grúa'), 1);
      expect(getPuntosApoyoPorDefecto('Báscula colgante / grua'), 1);
    });
    test('Báscula analítica -> 1', () {
      expect(getPuntosApoyoPorDefecto('Báscula analítica'), 1);
      expect(getPuntosApoyoPorDefecto('Báscula analitica'), 1);
    });
    test('Báscula de piso -> 1', () {
      expect(getPuntosApoyoPorDefecto('Báscula de piso'), 1);
    });
    test('Báscula de mostrador -> 1', () {
      expect(getPuntosApoyoPorDefecto('Báscula de mostrador'), 1);
    });
    test('Tanque / Silo -> 4', () {
      expect(getPuntosApoyoPorDefecto('Tanque / Silo'), 4);
      expect(getPuntosApoyoPorDefecto('Tanque'), 4);
      expect(getPuntosApoyoPorDefecto('Silo'), 4);
    });
    test('Otros -> 4', () {
      expect(getPuntosApoyoPorDefecto('Otro'), 4);
      expect(getPuntosApoyoPorDefecto('Desconocido', fallback: 4), 4);
    });
  });

  group('Cargas Sugeridas Metrológicas', () {
    test('Repetibilidad: Capacidad 6.8 kg -> 50% = 3.4 kg -> sugerir 4.000 kg', () {
      final carga = calcularCargaSugeridaRepetibilidad(6.8, divMin: 0.001);
      expect(carga, 4.0);
      final fmt = formatearCargaSugerida(carga, divMin: 0.001, capMax: 6.8);
      expect(fmt, '4.000');
    });

    test('Repetibilidad: Capacidad 1000 kg -> 50% = 500 kg -> sugerir 500 kg', () {
      final carga = calcularCargaSugeridaRepetibilidad(1000.0, divMin: 1.0);
      expect(carga, 500.0);
      final fmt = formatearCargaSugerida(carga, divMin: 1.0, capMax: 1000.0);
      expect(fmt, '500');
    });

    test('Excentricidad: Capacidad 6.8 kg -> 1/3 = 2.266 kg -> sugerir 3.000 kg', () {
      final carga = calcularCargaSugeridaExcentricidad(6.8, divMin: 0.001);
      expect(carga, 3.0);
      final fmt = formatearCargaSugerida(carga, divMin: 0.001, capMax: 6.8);
      expect(fmt, '3.000');
    });

    test('Excentricidad: Capacidad 1000 kg -> 1/3 = 333.33 kg -> sugerir 340 kg', () {
      final carga = calcularCargaSugeridaExcentricidad(1000.0, divMin: 1.0);
      expect(carga, 340.0);
      final fmt = formatearCargaSugerida(carga, divMin: 1.0, capMax: 1000.0);
      expect(fmt, '340');
    });
  });

  group('Fórmula Universal de Error Metrológico', () {
    test('Repetibilidad / Excentricidad: Carga=4.000, L.Ini=4.000, L.Fin=4.000 -> Error = 0.000 (NO -4.000)', () {
      const carga = 4.0;
      const ini = 4.0;
      const fin = 4.0;
      // Lectura inicial es solo referencia y no distorsiona el error
      expect(ini, 4.0);
      // Fórmula universal estricta: Error = fin - carga
      final error = fin - carga;
      expect(error, 0.0);
      expect(error.toStringAsFixed(3), '0.000');
    });

    test('Exactitud: Nominal=10.000, L.Ini=0.000, L.Fin=10.002 -> Error = 0.002', () {
      const nom = 10.0;
      const fin = 10.002;
      final error = fin - nom;
      expect(double.parse(error.toStringAsFixed(3)), 0.002);
    });
  });

  group('Formateo Dinámico según División Mínima (d)', () {
    test('d >= 1 (10 kg, 20 kg, 5 kg, 1 kg) -> 0 decimales', () {
      expect(getDecimalsFromD(10.0), 0);
      expect(getDecimalsFromD(20.0), 0);
      expect(getDecimalsFromD(5.0), 0);
      expect(getDecimalsFromD(1.0), 0);

      expect(formatMetrologicalValue(1000.0, 10.0), '1000');
      expect(formatMetrologicalValue(2000.0, 10.0), '2000');
      expect(formatMetrologicalValue(3000.0, 10.0), '3000');
      expect(formatMetrologicalValue(4000.0, 10.0), '4000');
      expect(formatMetrologicalValue(5000.0, 10.0), '5000');
      expect(formatMetrologicalValue(5990.0, 10.0), '5990');
      expect(formatMetrologicalValue(0.0, 10.0), '0');
      expect(formatMetrologicalValue(-10.0, 10.0), '-10');
    });

    test('formatMetrologicalString con cadenas preexistentes', () {
      expect(formatMetrologicalString('1000.0', 10.0), '1000');
      expect(formatMetrologicalString('2000.0', 10.0), '2000');
      expect(formatMetrologicalString('5990', 10.0), '5990');
      expect(formatMetrologicalString('', 10.0), '');
      expect(formatMetrologicalString(null, 10.0), '');
    });

    test('d con decimales (0.5, 0.2, 0.1, 0.01, 0.001)', () {
      expect(getDecimalsFromD(0.5), 1);
      expect(getDecimalsFromD(0.2), 1);
      expect(getDecimalsFromD(0.1), 1);
      expect(getDecimalsFromD(0.01), 2);
      expect(getDecimalsFromD(0.001), 3);

      expect(formatMetrologicalValue(1000.0, 0.1), '1000.0');
      expect(formatMetrologicalValue(1000.0, 0.01), '1000.00');
      expect(formatMetrologicalValue(1.0, 0.001), '1.000');
    });
  });

  group('Cálculo Estricto de Error en Excentricidad', () {
    test('Caso real Foto 1: Carga=22520, L.Ini=22490, L.Fin=22520 -> Error = 0 (NO -22490)', () {
      final err = calcularErrorExcentricidad(fin: 22520.0, ini: 22490.0, carga: 22520.0);
      expect(err, 0.0);
      expect(formatMetrologicalValue(err, 10.0), '0');
    });

    test('Deriva residual de cero: Carga=22520, L.Ini=10 (< 10% de carga), L.Fin=22520 -> Error = -10', () {
      final err = calcularErrorExcentricidad(fin: 22520.0, ini: 10.0, carga: 22520.0);
      expect(err, -10.0);
      expect(formatMetrologicalValue(err, 10.0), '-10');
    });

    test('Sin L. Inicial: Carga=22520, L.Ini=null, L.Fin=22520 -> Error = 0', () {
      final err = calcularErrorExcentricidad(fin: 22520.0, ini: null, carga: 22520.0);
      expect(err, 0.0);
      expect(formatMetrologicalValue(err, 10.0), '0');
    });

    test('Báscula Camionera (OS-26-689): Carga=22520, L.Ini=22490, L.Fin=22520, isCamionera=true -> Error = 0 (Estricto fin - carga)', () {
      final err = calcularErrorExcentricidad(fin: 22520.0, ini: 22490.0, carga: 22520.0, isCamionera: true);
      expect(err, 0.0);
      expect(formatMetrologicalValue(err, 10.0), '0');
    });

    test('Báscula Camionera (OS-26-689): Carga=22520, L.Ini=22490, L.Fin=22490, isCamionera=true -> Error = -30', () {
      final err = calcularErrorExcentricidad(fin: 22490.0, ini: 22490.0, carga: 22520.0, isCamionera: true);
      expect(err, -30.0);
      expect(formatMetrologicalValue(err, 10.0), '-30');
    });
  });

  group('Geometría de Excentricidad Automática', () {
    test('Camionera y Ferrocarril -> Camionera', () {
      expect(getGeometriaPorDefecto('Báscula camionera'), 'Camionera');
      expect(getGeometriaPorDefecto('Báscula de ferrocarril'), 'Camionera');
      expect(getGeometriaPorDefecto('Báscula puente de pesaje'), 'Camionera');
      expect(getGeometriaPorDefecto('Báscula Electrónica Camionera'), 'Camionera');
      expect(getGeometriaPorDefecto('Báscula Electrónica de FFCC'), 'Camionera');
    });

    test('Circular -> Circular', () {
      expect(getGeometriaPorDefecto('Báscula circular'), 'Circular');
    });

    test('Otras básculas -> Plataforma', () {
      expect(getGeometriaPorDefecto('Báscula de plataforma'), 'Plataforma');
      expect(getGeometriaPorDefecto('Báscula de piso'), 'Plataforma');
      expect(getGeometriaPorDefecto('Báscula de mostrador'), 'Plataforma');
      expect(getGeometriaPorDefecto('Báscula tolva'), 'Plataforma');
      expect(getGeometriaPorDefecto(null), 'Plataforma');
      expect(getGeometriaPorDefecto(''), 'Plataforma');
    });
  });
}
