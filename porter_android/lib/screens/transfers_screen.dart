import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/scanner_provider.dart';
import '../widgets/transfer_card.dart';

class TransfersScreen extends StatelessWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transfers')),
      body: Consumer<ScannerProvider>(
        builder: (context, provider, _) {
          final transfers = provider.allTransfers.values.toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          if (transfers.isEmpty) {
            return Center(
              child: Text(
                'No transfers yet — scan a QR code to begin.',
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: transfers.length,
            itemBuilder: (context, index) => TransferCard(transfer: transfers[index]),
          );
        },
      ),
    );
  }
}
