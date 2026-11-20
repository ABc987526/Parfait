import 'package:forui/forui.dart';
import 'package:flutter/widgets.dart';

import '../theme/forui_theme_bridge.dart';

/// Single collapsible item rendered inside an [AppAccordion].
class AppAccordionItem {
  const AppAccordionItem({
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  final Widget title;
  final Widget child;
  final bool initiallyExpanded;
}

/// Shared collapsible accordion backed by Forui's [FAccordion] and styled via
/// [ForuiThemeHost] so feature code never imports `package:forui/` directly.
class AppAccordion extends StatelessWidget {
  const AppAccordion({super.key, required this.items});

  final List<AppAccordionItem> items;

  @override
  Widget build(BuildContext context) {
    return ForuiThemeHost.ensure(
      context,
      FAccordion(
        children: [
          for (final item in items)
            FAccordionItem(
              title: item.title,
              initiallyExpanded: item.initiallyExpanded,
              child: item.child,
            ),
        ],
      ),
    );
  }
}
