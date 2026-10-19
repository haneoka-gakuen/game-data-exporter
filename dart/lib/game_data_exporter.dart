/// Current inventory facts from Otonote and MoeNotes exports.
library;

export 'gacha_history_analysis.dart';

part 'src/inventory.dart';
part 'src/third_party_inventory.dart';

const _rowsPerList = 5000;
final _decimal = RegExp(r'^(0|[1-9]\d{0,18})$');

int? _integer(Object? value) {
  final int? result;
  if (value is int) {
    result = value;
  } else if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble()) {
    result = value.toInt();
  } else if (value is String && _decimal.hasMatch(value)) {
    result = int.tryParse(value);
  } else {
    return null;
  }
  return result != null && result >= 0 && result <= 9007199254740991
      ? result
      : null;
}

int? _positiveId(Object? value) {
  final id = _integer(value);
  return id != null && id > 0 && id <= 0x7fffffff ? id : null;
}
