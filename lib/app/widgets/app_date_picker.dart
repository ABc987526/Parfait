import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/forui_theme_bridge.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared Forui calendar dialog returned by `showAppDatePicker`.
///
/// Dates are normalized to UTC calendar days internally to satisfy
/// [FCalendarController]'s UTC invariant while returning a local calendar date.
class AppDatePickerDialog extends StatefulWidget {
  const AppDatePickerDialog({
    super.key,
    required this.firstDate,
    required this.lastDate,
    required this.initialDate,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final DateTime initialDate;

  @override
  State<AppDatePickerDialog> createState() => _AppDatePickerDialogState();
}

class _AppDatePickerDialogState extends State<AppDatePickerDialog> {
  late final DateTime _startUtc = _toUtcDay(widget.firstDate);
  late final DateTime _endUtc = _toUtcDay(widget.lastDate);
  late final DateTime _todayUtc = _clampUtc(_toUtcDay(DateTime.now()));
  late DateTime _selectedUtc = _clampUtc(_toUtcDay(widget.initialDate));

  static DateTime _toUtcDay(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day);

  DateTime _clampUtc(DateTime day) {
    if (day.isBefore(_startUtc)) return _startUtc;
    if (day.isAfter(_endUtc)) return _endUtc;
    return day;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    return ForuiThemeHost.ensure(
      context,
      Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(FuncSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: FCalendar.grid(
                    control: FGridCalendarControl(
                      start: _startUtc,
                      end: _endUtc,
                      initial: _selectedUtc,
                      today: _todayUtc,
                    ),
                    selectionControl: FDateSelectionControl.liftedSingle(
                      value: _selectedUtc,
                      toggleable: false,
                      onChange: (picked) {
                        if (picked != null) {
                          setState(() => _selectedUtc = picked);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: FuncSpacing.md),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  spacing: FuncSpacing.sm,
                  overflowSpacing: FuncSpacing.sm,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(l10n.cancelButtonLabel),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(
                        DateTime(
                          _selectedUtc.year,
                          _selectedUtc.month,
                          _selectedUtc.day,
                        ),
                      ),
                      child: Text(l10n.okButtonLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
