import 'package:flutter/material.dart';
import 'package:collection/collection.dart';

class TransactionDataRow extends StatelessWidget {

  final List<dynamic> values;
  const TransactionDataRow({super.key, required this.values});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
      children: [
        FloatingActionButton(onPressed: (){}, child: Text("Do something"),),
        ...values.toList().whereIndexed((i, _) => i != 0 && i != 3).map(
          (val) => Expanded(child: Padding(
          padding: const EdgeInsets.all(8.0),
            child:Text(val.toString()
            ))
        )),
      ]
    ));
  }
}