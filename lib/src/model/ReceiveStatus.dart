/// Live status of this device's receive server, shared by [Core] and
/// [TransferServer] so both sides agree on a single type.
enum ReceiveStatus { waiting, incoming, completed }
