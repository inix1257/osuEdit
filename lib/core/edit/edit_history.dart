import '../model/beatmap.dart';
import 'commands.dart';

/// Undo/redo stack for one beatmap.
///
/// All user edits go through [execute]. Continuous gestures (dragging
/// objects) wrap their many small commands in a transaction so they undo as
/// one step:
///
/// ```dart
/// history.beginTransaction('Move objects');
/// history.execute(...); // many times while dragging
/// history.commitTransaction(); // or cancelTransaction() to roll back
/// ```
class EditHistory {
  final Beatmap beatmap;
  final int maxDepth;
  final void Function()? onChanged;

  /// Called after each edit step (an [execute] outside a transaction, or a
  /// [commitTransaction]) for changes that follow from it, e.g. regenerating
  /// breaks after objects moved. The returned (not yet applied) command is
  /// applied and joins the same undo step. Not called on undo / redo.
  EditCommand? Function()? followUp;

  final List<EditCommand> _undo = [];
  final List<EditCommand> _redo = [];

  String? _txLabel;
  List<EditCommand>? _tx;

  /// `_undo.length` at the last save; -1 when the saved state was dropped
  /// from the stack (then the map stays dirty until saved again).
  int _savePoint = 0;

  EditHistory(this.beatmap, {this.maxDepth = 500, this.onChanged, this.followUp});

  bool get canUndo => _tx == null && _undo.isNotEmpty;
  bool get canRedo => _tx == null && _redo.isNotEmpty;
  bool get inTransaction => _tx != null;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;
  bool get isDirty => _tx != null || _undo.length != _savePoint;

  /// The command the last [undo] / [redo] reverted or re-applied (null
  /// before any). Set before [onChanged] runs.
  EditCommand? get lastStep => _lastStep;
  EditCommand? _lastStep;

  void execute(EditCommand c) {
    c.apply(beatmap);
    if (_tx != null) {
      _tx!.add(c);
    } else {
      final f = _followUp();
      _push(f == null ? c : CompositeCommand(c.label, [c, f]));
    }
    onChanged?.call();
  }

  EditCommand? _followUp() {
    final f = followUp?.call();
    f?.apply(beatmap);
    return f;
  }

  void beginTransaction(String label) {
    if (_tx != null) throw StateError('Transaction already open');
    _txLabel = label;
    _tx = [];
  }

  void commitTransaction() {
    final tx = _tx;
    if (tx == null) throw StateError('No transaction open');
    _tx = null;
    if (tx.isNotEmpty) {
      final f = _followUp();
      if (f != null) tx.add(f);
      _push(tx.length == 1 ? tx.single : CompositeCommand(_txLabel!, tx));
    }
    _txLabel = null;
    onChanged?.call();
  }

  /// Reverts everything executed inside the open transaction.
  void cancelTransaction() {
    final tx = _tx;
    if (tx == null) return;
    _tx = null;
    _txLabel = null;
    for (final c in tx.reversed) {
      c.revert(beatmap);
    }
    onChanged?.call();
  }

  void _push(EditCommand c) {
    _undo.add(c);
    _redo.clear();
    if (_savePoint > _undo.length - 1) _savePoint = -1; // saved state lost
    if (_undo.length > maxDepth) {
      _undo.removeAt(0);
      if (_savePoint >= 0) _savePoint--;
    }
  }

  bool undo() {
    if (!canUndo) return false;
    final c = _undo.removeLast();
    c.revert(beatmap);
    _redo.add(c);
    _lastStep = c;
    onChanged?.call();
    return true;
  }

  bool redo() {
    if (!canRedo) return false;
    final c = _redo.removeLast();
    c.apply(beatmap);
    _undo.add(c);
    _lastStep = c;
    onChanged?.call();
    return true;
  }

  /// Whether the last saved state can be reached by undoing or redoing.
  bool get canReachSavePoint =>
      _tx == null && _savePoint >= 0 && _savePoint <= _undo.length + _redo.length;

  /// Undoes (or redoes) back to the last saved state. False, changing
  /// nothing, when [canReachSavePoint] is false. [lastStep] is left alone.
  bool reachSavePoint() {
    if (!canReachSavePoint) return false;
    final last = _lastStep;
    while (_undo.length > _savePoint) {
      undo();
    }
    while (_undo.length < _savePoint) {
      redo();
    }
    _lastStep = last;
    return true;
  }

  /// Marks the map as differing from its file although nothing is on the
  /// undo stack (opened from an autosave).
  void markUnsaved() {
    _savePoint = -1;
    onChanged?.call();
  }

  void markSaved() {
    _savePoint = _undo.length;
    onChanged?.call();
  }
}
