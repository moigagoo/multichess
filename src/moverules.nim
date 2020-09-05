import latticenodes, boards, moves, positions, playercolors, pieces
import tables

iterator getAllPossibleMoves(rootNode: MCLatticeNode[MCBoard]): MCMove =
  for node in rootNode.getNodesNeedingMove():
    for pos in node.iterPositions():
      for move in pos.getPseudoLegalMoves():
        yield move

iterator getAllPseudoLegalMoves*(rootNode: MCLatticeNode[MCBoard],
                                otherPlayer = false): MCMove =
  for node in rootNode.getNodesNeedingMove():
    for pos in node.iterPositions():
      if otherPlayer xor (node.board.toPlay == pos.getSquare().color):
        for move in pos.getPseudoLegalMoves():
          yield move

proc isMoveBlatantlyIllegal(m: MCMove): bool =
  ## Returns true if a move is blatantly illegal. "Blatantly illegal"
  ## means either the piece trying to be moved doesn't exist, or it's
  ## trying to move onto a piece of its same color. Or, it's not that
  ## piece's color's turn.

  let fromPos = m.fromPos
  let toPos = m.toPos
  let fromSquare = fromPos.getSquare()
  let toSquare = toPos.getSquare()

  if not fromPos.hasPiece():
    return true

  # not your turn
  if fromPos.node.board.toPlay != fromSquare.color:
    return true

  # piece trying to move onto piece of same color
  if toSquare.hasPiece and toSquare.color == fromSquare.color:
    return true

proc makeMove*(move: MCMove): MCMoveInfo =
  result.move = move
  result.realToNode = nil
  result.newFromNode = nil
  let fromPos = move.fromPos
  let toPos = move.toPos
  let square = fromPos.getSquare()
  let fromNode = fromPos.node
  let toNode = toPos.node
  let otherPlayer = oppositeColor(square.color)

  let preferredSiblingDirection =
    if square.color == mccWhite:
      mclsPrev
    else:
      mclsNext

  var bcopy = toNode.board

  if not move.isTimeJump:
    bcopy[fromPos.file, fromPos.rank] = (mcpNone, mccWhite)

  bcopy[toPos.file, toPos.rank] = square
  bcopy.toPlay = otherPlayer

  result.realToNode = toPos.node.branch(bcopy, preferredSiblingDirection)

  if move.isTimeJump:
    let newFromNode = fromNode.branch(fromNode.board, preferredSiblingDirection)
    newFromNode.board[fromPos.file, fromPos.rank] = (mcpNone, mccWhite)
    newFromNode.board.toPlay = otherPlayer
    result.newFromNode = newFromNode

# WARNING: Dangerous
proc undoMove*(info: MCMoveInfo) =
  let lastMove = info.move
  let realToNode = info.realToNode
  # For normal moves, this should be all there is to do
  realToNode.unlinkLeaf()
  if lastMove.isTimeJump():
    # This is where the piece moved
    let moved = realToNode.board[lastMove.toPos]
    # Put it back where it was
    lastMove.fromPos.node.board[lastMove.fromPos] = moved
    let newFromNode = info.newFromNode
    assert(not newFromNode.isNil)
    newFromNode.unlinkLeaf()

proc checksInPosition*(rootNode: MCLatticeNode[MCBoard]): seq[MCMove] =
  for move in rootNode.getAllPossibleMoves():
    let fromSquare = move.fromPos.getSquare()
    let toSquare = move.toPos.getSquare()
    if toSquare.piece == mcpKing and fromSquare.color == oppositeColor(toSquare.color):
      result.add(move)

proc isMoveLegal*(rootNode: MCLatticeNode[MCBoard], move: MCMove): bool =
  if move.isMoveBlatantlyIllegal():
    result = false
    return

  let info = move.makeMove()

  result = true

  let checks = rootNode.checksInPosition()
  let fromColor = move.fromPos.getSquare().color
  for check in checks:
    if check.toPos.getSquare().color == fromColor:
      result = false
      break

  info.undoMove()

iterator getAllLegalMoves*(rootNode: MCLatticeNode[MCBoard]): MCMove =
  for move in rootNode.getAllPseudoLegalMoves():
    if rootNode.isMoveLegal(move):
      yield move

iterator getAllLegalMovesAt*(rootNode: MCLatticeNode[MCBoard], pos: MCPosition): MCMove =
  if pos.node.needsMove:
    for move in pos.getPseudoLegalMoves():
      if rootNode.isMoveLegal(move):
        yield move
