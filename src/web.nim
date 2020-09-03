include karax/prelude
import karax/vstyles
import options, tables, sets, json, random, streams
import dom, asyncjs
import html5_canvas
import peerjs
include multichess
import piececlasses, boardeditor, gameview, rpcs, clipboard

# Constants

## Don't forget to change this if the css changes!
const squareSizePixels = 40

type
  LogEntry = tuple
    message: cstring
    color: cstring

  MCClientStatus = enum
    stConfig, stGame, stGameEnd
  MCClient = ref object
    view: Option[MCGameView]
    status: MCClientStatus
    boardEditor: MCBoardEditor
    master: bool
    id, peerid: PeerID
    pcolor: MCPlayerColor
    rpc: SimpleRPCPeer
    rpcInitialized: bool

  GameInitMessage = object
    opponentId: string
    board: MCBoard
    color: MCPlayerColor

# Client
proc newMCClient(): MCClient =
  new result
  result.view = none[MCGameView]()
  result.status = stConfig
  result.master = false
  # dummy value, will be overwritten later
  result.rpc = initSimpleRPCPeer(proc(data: cstring) = discard)
  result.rpcInitialized = false
  result.id = nil
  result.peerid = nil
  result.pcolor = rand(mccWhite..mccBlack)

proc dumpGameToClipboard(cl: MCClient) =
  cl.view.map do (v: MCGameView):
    let s = newStringStream()
    s.write(v.game)
    copyToClipboard(s.data)

proc getBoardContainerStyle(left: int, top: int): VStyle =
  style(
    (StyleAttr.position, cstring"absolute"),
    (StyleAttr.left, cstring($left & "px")),
    (StyleAttr.top, cstring($top & "px")))

proc render(board: MCBoard): VNode =
  result = buildHtml(tdiv):
    tdiv(class="board"):
      for r in countdown(board.numRanks-1, 0):
        for f in countup(0, board.numFiles-1):
          let blackSquareClass = if (f + r) mod 2 == 0:
                                   kstring("square square-black")
                                 else:
                                   kstring("square square-white")

          tdiv(class=blackSquareClass):
            tdiv(class=getClassFor(board[f, r]))

        br()

proc renderBoardTest(): VNode =
  return render(mcStartPos5x5)

# Can't get karax to properly render SVG so I have to do this for now,
# don't worry about this code it's going to be replaced with much
# better SVG.
proc drawGameView(state: MCGameView, canvas: Canvas) =
  # size constants
  let f = state.game.rootNode.board.numFiles
  let r = state.game.rootNode.board.numRanks
  let w = float((f + 2) * squareSizePixels)
  let h = float((r + 2) * squareSizePixels)
  let dcx = f * squareSizePixels / 2
  let dcy = r * squareSizePixels / 2

  let (lw, lh) = state.layout.dims()

  let cc = document.querySelector(".client-container")
  canvas.width = lw * (f + 2) * squareSizePixels
  canvas.height = lh * (f + 2) * squareSizePixels
  let ctx = canvas.getContext2D()

  # Invert the table for sanity later, will have to look up a node's
  # position
  var placement = initTable[MCLatticeNode[MCBoard], MCLayoutPosition]()
  for np, node in state.layout.placement:
    placement[node] = np

  proc center(node: MCLatticeNode[MCBoard]): (float, float) {.closure.} =
    let np = placement[node]
    let (x, y) = (float(np[0]), float(np[1]))
    return (x * w + dcx, y * h + dcy)
    
  for node, np in placement:
    let (cx, cy) = center(node)

    for child in node.future:
      let (ccx, ccy) = center(child)
      ctx.strokeStyle = "blue"
      ctx.moveTo(cx, cy)
      ctx.lineTo(ccx, ccy)
      ctx.stroke()
    if not node.nextSibling.isNil:
      let (ccx, ccy) = center(node.nextSibling)
      ctx.strokeStyle = "green"
      ctx.moveTo(cx, cy)
      ctx.lineTo(ccx, ccy)
      ctx.stroke()

proc squareOnClick(cl: MCClient): proc(ev: Event, n: Vnode) =
  let state = cl.view.get()
  return proc(ev: Event, n: VNode) {.closure.} =
           # Note: using a closure for these parameters DOES NOT work
           # with karax (as of 2020 August 29). The event listeners
           # seem to be getting screwed up so we can't rely on passing
           # anything in by closure that isn't a constant.
           let target = ev.target
           if target.getAttribute("file").isNil: return
           let np = (parseInt(target.getAttribute("posx")),
                     parseInt(target.getAttribute("posy")))
           let file = parseInt(target.getAttribute("file"))
           let rank = parseInt(target.getAttribute("rank"))
           let node = state.layout.placement[np]
           let clickedPos = pos(node, file, rank)
           if state.isSelected(clickedPos):
             state.clearSelection()
           elif state.isPossibleMove(clickedPos):
             ## TODO: PROMOTION
             state.selectedPosition.map(
               proc(sp: MCPosition) =
                 let move = mv(sp, clickedPos, mcpNone)
                 state.makeMove(move)
                 discard cl.rpc.client.call("gamemove", %* move))
           else:
             if clickedPos.hasPiece():
               state.click(clickedPos)
               state.selectPosition(clickedPos)

proc renderGame(client: MCClient): VNode =
  let state = client.view.get()
  var game = state.game

  # See comment on drawGameView... bleh. It even makes me have to do
  # this. Pray that your DOM renders in 10ms (or whatever's after the
  # proc argument)
  discard window.setTimeout(
    proc() =
      let cnv = document.getElementById("backdrop")
      if not cnv.isNil: state.drawGameView(cast[Canvas](cnv)),
    10)

  var actionableBoards: HashSet[MCLatticeNode[MCBoard]]
  for mpos, moves in state.currentLegalMoves:
    if len(moves) > 0:
      actionableBoards.incl(mpos.node)

  result = buildHtml(tdiv):
    if state.isSinglePlayer():
      button(onclick=proc() = state.undoLastMove()):
        text "oops"
      
    tdiv(class="client-container"):
      canvas(class="client-hints", id="backdrop")
      for np, node in state.layout.placement:
        let isActionable = node in actionableBoards
        let (x, y) = np
        let w = (node.board.numFiles + 2) * (squareSizePixels)
        let h = (node.board.numRanks + 2) * (squareSizePixels)

        tdiv(class="board-container", style=getBoardContainerStyle(x * w, y * h)):
          let onclick = squareOnClick(client)
          var boardClass = "board"
          if isActionable: boardClass &= " board-actionable"
          tdiv(class=boardClass, onclick=onclick):
            let board = node.board
            for r in countdown(board.numRanks - 1, 0):
              for f in countup(0, board.numFiles - 1):
                let blackSquareClass = if (f + r) mod 2 == 0:
                                         kstring("square square-black")
                                       else:
                                         kstring("square square-white")

                let elPos = pos(node, f, r)
                tdiv(class=blackSquareClass):
                  tdiv(class=getClassFor(elPos.getSquare()),
                       file=kstring($f),
                       rank=kstring($r),
                       posx=kstring($x),
                       posy=kstring($y))

                  if state.isPossibleMove(elPos):
                      tdiv(class="highlight highlight-move")
                  if state.isSelected(elPos):
                      tdiv(class="highlight highlight-select")
                  if state.isChecked(elPos) or state.isHighlighted(elPos):
                      tdiv(class="highlight highlight-check")

              br()

proc render(cl: MCClient): VNode =
  result = buildHtml(tdiv):
    case cl.status:
      of stConfig:
        if not cl.id.isNil:
          text "peer id: "
          text cl.id
        if cl.peerid.isNil:
          text " not connected."
        else:
          text " connected to "
          text cl.peerid

        br()
        text "multichess!"
        br()
        text "start a game!"
        br()
        text "but first, a starting position"
        br()
        render(cl.boardEditor)
      of stGame, stGameEnd:
        renderGame(cl)


proc renderPieceTest(): VNode =
  result = buildHtml(tdiv):
    tdiv(class="piece piece-king-white")
    tdiv(class="piece piece-king-black")
    br()
    tdiv(class="piece piece-queen-white")
    tdiv(class="piece piece-queen-black")
    br()
    tdiv(class="piece piece-rook-white")
    tdiv(class="piece piece-rook-black")
    br()
    tdiv(class="piece piece-bishop-white")
    tdiv(class="piece piece-bishop-black")
    br()
    tdiv(class="piece piece-knight-white")
    tdiv(class="piece piece-knight-black")
    br()
    tdiv(class="piece piece-pawn-white")
    tdiv(class="piece piece-pawn-black")

proc sendGameInit(client: MCClient): JsonNode {.async.} =
  let gameInitMessage = GameInitMessage(
    opponentId: $client.id,
    board: client.view.get().game.rootNode.board,
    color: oppositeColor(client.pcolor))

  let resp = await client.rpc.client.call("gameinit", %* gameInitMessage)

proc onConnectionOpen(client: MCClient, conn: DataConnection) {.async.} =
  client.peerid = conn.peer
  redraw()
  if not client.master:
    return
  if not client.view.isSome():
    return

proc onConnectionClose(client: MCClient, conn: DataConnection) =
  echo "connection closed with ", conn.peer

proc registerConnection(client: MCClient, conn: DataConnection) {.async.} =
  client.rpc = initSimpleRPCPeer(proc(data: cstring) = conn.send(data))
  client.rpcInitialized = true
  client.rpc.server.register("gameinit") do (arg: JsonNode) -> JsonNode:
    let msg = to(arg, GameInitMessage)
    let pcolor = msg.color
    echo "GAMEINIT ", arg
    client.status = stGame
    client.view = some(newGameView(initGame(msg.board), some(pcolor)))
    redraw()
    %*"ok"

  client.rpc.server.register("gamemove") do (arg: JsonNode) -> JsonNode:
    echo "GAMEMOVE ", arg
    let view = client.view.get()
    let move = view.game.toMove(arg)
    view.makeMove(move)
    redraw()
    %*"ok"
                             
  conn.on("data", proc(data: cstring) = recv(client.rpc, data))

  conn.on("open") do (x: cstring):
    discard client.onConnectionOpen(conn)
    
  conn.on("close") do (x: cstring):
    client.onConnectionClose(conn)
  conn.on("disconnected") do (x: cstring):
    client.onConnectionClose(conn)
                         

proc initPeer(p: Peer, id: cstring, client: MCClient) {.async.} =
  client.id = id
  let wh = window.location.hash
  if len(wh) == 0:
    client.master = true
    p.on("connection") do (conn: DataConnection):
      discard client.registerConnection(conn)
  else:
    client.master = false
    let conn = p.connect(($wh)[1..^1])
    await client.registerConnection(conn)

proc main() {.async.} =
  let p = newPeer()
  let client = newMCClient()
  client.boardEditor = newBoardEditor(mcStartPos5x5) do (b: MCBoard):
    # If we supply none as the player color, then the player will be
    # able to play for both colors. So, we check if a peer is
    # connected and if so, we use our randomly generated
    # client.pcolor.
    var pcolor = none[MCPlayerColor]()
    if not client.peerid.isNil:
      pcolor = some(client.pcolor)

    client.status = stGame
    client.view = some(newGameView(initGame(b), pcolor))

    if client.rpcInitialized:
      discard client.sendGameInit()

  p.on("open", proc(id: cstring) =
                 discard initPeer(p, id, client)
                 redraw())

  p.on("error", proc(err: PeerError) =
                  if err.`type` == "peer-unavailable":
                    discard #TODO
                  else:
                    raise newException(Exception, "peer error: {%err}"))


  proc renderClient(): VNode =
    render(client)

  setRenderer renderClient

when isMainModule:
  randomize()
  discard main()
