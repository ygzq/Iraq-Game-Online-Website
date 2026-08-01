cat > server.js << 'EOF'
const path = require('path');
const express = require('express');
const http = require('http');
const { Server } = require('socket.io');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  maxHttpBufferSize: 5e7 // 50MB (لأن الصور base64 قد تكون كبيرة)
});

app.use(express.static(path.join(__dirname, 'public')));

const rooms = {};

function playerKey(team, name) { return `${team}:${name}`; }

function freshRoom(roomCode) {
  return {
    code: roomCode,
    players: {},
    redLeaderName: null,
    blueLeaderName: null,
    adminKey: null, // مفتاح اللاعب الذي أنشأ الغرفة - هو الوحيد المخوّل بالتحكم
    images: { red: null, blue: null },
    scores: { red: 0, blue: 0 },
    roundNumber: 1,
    hintUsed: { red: false, blue: false },
    skipUsed: { red: false, blue: false },
    started: false
  };
}

function teamCount(room, team) {
  return Object.values(room.players).filter(p => p.team === team).length;
}

function publicRoomState(room) {
  return {
    players: room.players,
    redLeaderName: room.redLeaderName,
    blueLeaderName: room.blueLeaderName,
    scores: room.scores,
    roundNumber: room.roundNumber
  };
}

// تحقق أن الطلب قادم من نفس السوكيت الخاص بمنشئ الغرفة (الأدمن) فقط
function isRoomAdmin(room, socketId) {
  if (!room.adminKey) return false;
  const admin = room.players[room.adminKey];
  return !!admin && admin.socketId === socketId;
}

// يجد بيانات اللاعب صاحب هذا السوكيت داخل الغرفة
function findPlayerBySocket(room, socketId) {
  return Object.values(room.players).find(p => p.socketId === socketId);
}

io.on('connection', (socket) => {

  socket.on('create_room', ({ roomCode, playerName, team }) => {
    if (!roomCode || !playerName || !team) return;
    if (rooms[roomCode]) {
      socket.emit('error_msg', 'رمز الغرفة مستخدم بالفعل، حاول مرة أخرى.');
      return;
    }
    const room = freshRoom(roomCode);
    const key = playerKey(team, playerName);
    room.players[key] = { name: playerName, team, isCaptain: true, socketId: socket.id };
    if (team === 'red') room.redLeaderName = playerName; else room.blueLeaderName = playerName;
    room.adminKey = key; // منشئ الغرفة = الأدمن الوحيد المخوّل بمنح النقاط وبدء الجولات
    rooms[roomCode] = room;

    socket.join(roomCode);
    socket.emit('room_joined_successfully', { roomCode });
    io.to(roomCode).emit('update_room_state', publicRoomState(room));
  });

  socket.on('join_room', ({ roomCode, playerName, team }) => {
    const room = rooms[roomCode];
    if (!room) { socket.emit('error_msg', 'لا توجد غرفة بهذا الرمز.'); return; }
    if (teamCount(room, team) >= 4) { socket.emit('error_msg', 'هذا الفريق ممتلئ (٤ لاعبين).'); return; }

    const key = playerKey(team, playerName);
    const isCaptain = !(team === 'red' ? room.redLeaderName : room.blueLeaderName);
    room.players[key] = { name: playerName, team, isCaptain, socketId: socket.id };
    if (isCaptain) {
      if (team === 'red') room.redLeaderName = playerName; else room.blueLeaderName = playerName;
    }

    socket.join(roomCode);
    socket.emit('room_joined_successfully', { roomCode });
    io.to(roomCode).emit('update_room_state', publicRoomState(room));
  });

  socket.on('reconnect_player', ({ roomCode, playerName, team }) => {
    const room = rooms[roomCode];
    if (!room) return;
    socket.join(roomCode);
    const key = playerKey(team, playerName);
    if (room.players[key]) {
      room.players[key].socketId = socket.id;
    } else {
      const isCaptain = !(team === 'red' ? room.redLeaderName : room.blueLeaderName);
      room.players[key] = { name: playerName, team, isCaptain, socketId: socket.id };
      if (isCaptain) {
        if (team === 'red') room.redLeaderName = playerName; else room.blueLeaderName = playerName;
      }
    }
    io.to(roomCode).emit('update_room_state', publicRoomState(room));
    socket.emit('feature_status_update', { hintUsed: room.hintUsed, skipUsed: room.skipUsed });
  });

  socket.on('rename_player', ({ roomCode, oldName, newName, team }) => {
    const room = rooms[roomCode];
    if (!room || !oldName || !newName) return;
    const oldKey = playerKey(team, oldName);
    const player = room.players[oldKey];
    if (!player) return;

    delete room.players[oldKey];
    player.name = newName;
    const newKey = playerKey(team, newName);
    room.players[newKey] = player;

    if (player.isCaptain) {
      if (team === 'red') room.redLeaderName = newName; else room.blueLeaderName = newName;
    }
    if (room.adminKey === oldKey) room.adminKey = newKey; // حافظ على صلاحية الأدمن بعد تغيير اسمه

    io.to(roomCode).emit('update_room_state', publicRoomState(room));
  });

  socket.on('admin_trigger_start', ({ roomCode }) => {
    const room = rooms[roomCode];
    if (!room) return;
    if (!isRoomAdmin(room, socket.id)) {
      socket.emit('error_msg', 'فقط منشئ الغرفة (الأدمن) يمكنه بدء التحدي.');
      return;
    }
    if (!room.redLeaderName || !room.blueLeaderName) {
      socket.emit('error_msg', 'يجب أن ينضم قائدا الفريقين قبل البدء.');
      return;
    }
    room.started = true;
    room.roundNumber = 1;
    room.images = { red: null, blue: null };
    io.to(roomCode).emit('force_go_to_prep', { roundNumber: room.roundNumber });
  });

  socket.on('team_image_ready', ({ roomCode, team, image }) => {
    const room = rooms[roomCode];
    if (!room) return;
    room.images[team] = image;
    const redReady = !!room.images.red;
    const blueReady = !!room.images.blue;
    io.to(roomCode).emit('prep_status_update', { redReady, blueReady });

    if (redReady && blueReady) {
      room.hintUsed = { red: false, blue: false };
      room.skipUsed = { red: false, blue: false };
      io.to(roomCode).emit('start_game_round', {
        roundNumber: room.roundNumber,
        redImage: room.images.red,
        blueImage: room.images.blue,
        redLeaderName: room.redLeaderName,
        blueLeaderName: room.blueLeaderName
      });
      io.to(roomCode).emit('feature_status_update', { hintUsed: room.hintUsed, skipUsed: room.skipUsed });
    }
  });

  // فقط قائد الفريق يمكنه طلب التلميح
  socket.on('request_hint', ({ roomCode, team }) => {
    const room = rooms[roomCode];
    if (!room) return;
    const player = findPlayerBySocket(room, socket.id);
    if (!player || player.team !== team || !player.isCaptain) {
      socket.emit('error_msg', 'فقط قائد الفريق هو من يستطيع طلب التلميح.');
      return;
    }
    if (room.hintUsed[team]) return;
    room.hintUsed[team] = true;
    const opponentTeam = team === 'red' ? 'blue' : 'red';
    io.to(roomCode).emit('notify_hint_requested', { fromTeam: team, toTeam: opponentTeam });
    io.to(roomCode).emit('feature_status_update', { hintUsed: room.hintUsed, skipUsed: room.skipUsed });
  });

  // فقط قائد الفريق يمكنه التخطي
  socket.on('skip_question', ({ roomCode, team }) => {
    const room = rooms[roomCode];
    if (!room) return;
    const player = findPlayerBySocket(room, socket.id);
    if (!player || player.team !== team || !player.isCaptain) {
      socket.emit('error_msg', 'فقط قائد الفريق هو من يستطيع تخطي السؤال.');
      return;
    }
    if (room.skipUsed[team]) return;
    room.skipUsed[team] = true;
    const opponentTeam = team === 'red' ? 'blue' : 'red';
    io.to(roomCode).emit('notify_skip_requested', { fromTeam: team, toTeam: opponentTeam });
    io.to(roomCode).emit('feature_status_update', { hintUsed: room.hintUsed, skipUsed: room.skipUsed });
  });

  socket.on('end_round', ({ roomCode, winnerTeam }) => {
    const room = rooms[roomCode];
    if (!room) return;
    if (!isRoomAdmin(room, socket.id)) {
      socket.emit('error_msg', 'فقط الأدمن (منشئ الغرفة) يمكنه تحديد الفريق الفائز بالجولة.');
      return;
    }
    if (winnerTeam === 'red') room.scores.red += 1;
    else if (winnerTeam === 'blue') room.scores.blue += 1;

    io.to(roomCode).emit('round_ended', {
      scores: room.scores,
      redLeaderName: room.redLeaderName,
      blueLeaderName: room.blueLeaderName
    });
  });

  socket.on('next_round_prep', ({ roomCode }) => {
    const room = rooms[roomCode];
    if (!room) return;
    if (!isRoomAdmin(room, socket.id)) {
      socket.emit('error_msg', 'فقط الأدمن (منشئ الغرفة) يمكنه الانتقال للجولة التالية.');
      return;
    }
    room.roundNumber += 1;
    room.images = { red: null, blue: null };
    io.to(roomCode).emit('force_go_to_prep', { roundNumber: room.roundNumber });
  });

  socket.on('disconnect', () => {
    // نُبقي بيانات اللاعب في الغرفة لأنه قد يعيد الاتصال بنفس الاسم/الفريق
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`✅ Server running on http://localhost:${PORT}`);
});
EOF







cat > public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1">
<title>ملف القضية السرية | قائد ضد قائد</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Rakkas&family=Tajawal:wght@400;500;700;900&display=swap" rel="stylesheet">
<style>
  :root{
    --cork:#8a6b45; --cork-dark:#5f4529; --cork-line:#725636;
    --paper:#f3e9d2; --paper-dark:#e6d8b8; --ink:#2b2116; --ink-soft:#5b4b36;
    --red:#c1443c; --red-dark:#7e2b26; --red-glow:rgba(193,68,60,.35);
    --blue:#2e5c8a; --blue-dark:#1c3a58; --blue-glow:rgba(46,92,138,.35);
    --gold:#e0a927; --gold-dark:#a67a17;
    --shadow: rgba(20,12,4,.55);
  }
  *{box-sizing:border-box;}
  html,body{margin:0;padding:0;}
  body{
    font-family:'Tajawal',sans-serif; color:var(--ink); min-height:100vh;
    background:
      radial-gradient(circle at 20% 15%, rgba(255,255,255,.05), transparent 40%),
      radial-gradient(circle at 80% 85%, rgba(255,255,255,.04), transparent 40%),
      repeating-linear-gradient(45deg, var(--cork) 0 2px, var(--cork-line) 2px 4px),
      var(--cork-dark);
    background-blend-mode: normal;
    padding:18px 10px 60px;
  }
  h1,h2,h3,h4{ font-family:'Rakkas',cursive; font-weight:400; margin:0 0 6px; }
  .wrap{ max-width:640px; margin:0 auto; }
  .case-title{ text-align:center; color:var(--paper); font-size:30px; text-shadow:0 3px 0 rgba(0,0,0,.4); margin-bottom:4px; }
  .case-sub{ text-align:center; color:#e9dcc0; font-size:13px; opacity:.85; margin-bottom:20px; letter-spacing:.5px;}

  .screen{ display:none; }
  .screen.active{ display:block; }

  .card{
    position:relative; background:var(--paper); border-radius:6px;
    box-shadow:0 14px 28px var(--shadow), inset 0 0 0 1px rgba(0,0,0,.05);
    padding:26px 20px 22px; margin-bottom:18px;
    background-image: radial-gradient(rgba(0,0,0,.035) 1px, transparent 1px);
    background-size:6px 6px;
  }
  .card.tilt-l{ transform:rotate(-0.6deg); }
  .card.tilt-r{ transform:rotate(0.6deg); }
  .pin{
    position:absolute; top:-11px; left:50%; transform:translateX(-50%);
    width:20px; height:20px; border-radius:50%;
    background: radial-gradient(circle at 35% 30%, #fff6, transparent 40%), var(--gold);
    box-shadow:0 3px 5px rgba(0,0,0,.5), inset 0 -2px 3px var(--gold-dark);
    border:1px solid var(--gold-dark);
  }
  .pin.red{ background: radial-gradient(circle at 35% 30%, #fff6, transparent 40%), var(--red); box-shadow:0 3px 5px rgba(0,0,0,.5), inset 0 -2px 3px var(--red-dark); border-color:var(--red-dark);}
  .pin.blue{ background: radial-gradient(circle at 35% 30%, #fff6, transparent 40%), var(--blue); box-shadow:0 3px 5px rgba(0,0,0,.5), inset 0 -2px 3px var(--blue-dark); border-color:var(--blue-dark);}

  p.lead{ color:var(--ink-soft); font-size:14px; margin:0 0 14px; }

  input[type=text]{
    width:100%; padding:13px 14px; font-size:16px; border-radius:8px;
    border:2px solid var(--paper-dark); background:#fffdf7; color:var(--ink);
    font-family:'Tajawal',sans-serif; text-align:center; margin-bottom:10px;
  }
  input[type=text]:focus{ outline:none; border-color:var(--gold-dark); }

  button{
    font-family:'Tajawal',sans-serif; font-weight:700; font-size:15px; cursor:pointer;
    border:none; border-radius:9px; padding:13px 16px; transition:.15s transform, .15s box-shadow;
    box-shadow:0 4px 0 rgba(0,0,0,.25);
  }
  button:active{ transform:translateY(3px); box-shadow:0 1px 0 rgba(0,0,0,.25); }
  button:disabled{ background:#b9ac8e !important; color:#75694f !important; box-shadow:none !important; cursor:not-allowed; transform:none !important; }
  .btn-block{ width:100%; }
  .btn-gold{ background:var(--gold); color:#2b2000; }
  .btn-red{ background:var(--red); color:#fff; }
  .btn-blue{ background:var(--blue); color:#fff; }
  .btn-ghost{ background:var(--paper-dark); color:var(--ink); }
  .btn-dark{ background:var(--ink); color:var(--paper); }
  .btn-tiny{ padding:5px 10px; font-size:11px; border-radius:14px; box-shadow:0 2px 0 rgba(0,0,0,.25); }

  .team-picker{ display:flex; gap:12px; margin:14px 0; }
  .team-opt{
    flex:1; padding:16px 8px; border-radius:10px; text-align:center; cursor:pointer;
    border:3px solid transparent; transition:.15s;
  }
  .team-opt.red{ background:linear-gradient(180deg,#e0655c,var(--red)); color:#fff; }
  .team-opt.blue{ background:linear-gradient(180deg,#4c7fae,var(--blue)); color:#fff; }
  .team-opt small{ display:block; font-size:11px; opacity:.85; margin-top:4px; }
  .team-opt.disabled{ opacity:.4; cursor:not-allowed; filter:grayscale(.6); }
  .team-opt.selected{ border-color:var(--gold); box-shadow:0 0 0 3px rgba(224,169,39,.4); }

  .divider{ border:none; border-top:2px dashed var(--paper-dark); margin:18px 0; }

  .link-box{
    background:#fffdf7; border:1px dashed var(--ink-soft); border-radius:8px;
    padding:10px; font-family:monospace; font-size:12.5px; word-break:break-all; color:var(--blue-dark);
    margin:8px 0 4px;
  }
  .invite-block{ margin-bottom:14px; }
  .invite-block h4{ font-size:13.5px; margin-bottom:4px; }
  .invite-block h4.red-label{ color:var(--red-dark); }
  .invite-block h4.blue-label{ color:var(--blue-dark); }
  .code-badge{
    display:inline-block; background:var(--ink); color:var(--gold); font-family:'Rakkas';
    letter-spacing:4px; padding:8px 18px; border-radius:8px; font-size:20px; margin:6px 0 10px;
  }

  .roster{ display:flex; gap:10px; margin-top:12px; }
  .roster .side{ flex:1; background:#fffdf7; border-radius:8px; padding:10px; border-top:4px solid; }
  .roster .side.red{ border-color:var(--red); }
  .roster .side.blue{ border-color:var(--blue); }
  .roster h4{ font-family:'Tajawal'; font-weight:900; font-size:13px; margin:0 0 6px; }
  .roster ul{ list-style:none; margin:0; padding:0; font-size:12.5px; }
  .roster li{ padding:2px 0; color:var(--ink-soft); }
  .roster li.captain{ color:var(--ink); font-weight:700; }
  .roster li.captain::before{ content:"👑 "; }
  .roster .empty-slot{ color:#b7a98a; }

  .status-badge{
    display:block; text-align:center; padding:9px 14px; border-radius:20px; font-size:13px;
    font-weight:700; margin-top:10px;
  }
  .status-waiting{ background:rgba(193,68,60,.12); color:var(--red-dark); border:1.5px solid var(--red); }
  .status-ready{ background:rgba(46,140,90,.14); color:#1e6b45; border:1.5px solid #2f9c63; }

  .scoreboard{
    display:flex; align-items:center; justify-content:space-between; background:var(--ink); color:var(--paper);
    border-radius:10px; padding:12px 16px; margin-bottom:14px; box-shadow:0 6px 0 rgba(0,0,0,.3);
    position:sticky; top:6px; z-index:60;
  }
  .scoreboard .team-score{ text-align:center; flex:1; }
  .scoreboard .team-score b{ font-size:22px; display:block; }
  .scoreboard .vs{ font-family:'Rakkas'; color:var(--gold); font-size:18px; padding:0 10px; }
  .scoreboard .name{ font-size:11px; opacity:.75; }

  .admin-only-note{
    text-align:center; font-size:11.5px; color:var(--gold); background:rgba(224,169,39,.12);
    border:1px dashed var(--gold-dark); border-radius:8px; padding:6px 8px; margin:-4px 0 14px;
  }

  /* ===== مشهد الشخصية الجالسة تحمل الصورة ===== */
  .scene-viewport{ perspective: 1000px; }
  .char-scene{
    position:relative; height:330px; border-radius:10px; overflow:hidden;
    background:
      radial-gradient(circle at 22% 15%, rgba(255,235,180,.35), transparent 45%),
      linear-gradient(180deg, #d9b48a 0%, #d9b48a 66%, #7a5a3a 66%, #7a5a3a 100%);
    box-shadow: inset 0 0 40px rgba(0,0,0,.35);
    transform-style: preserve-3d;
    transition: transform .08s linear;
    cursor: grab;
    touch-action: pan-y;
    user-select: none;
  }
  .char-scene:active{ cursor:grabbing; }
  .char-scene::before{
    content:''; position:absolute; top:18px; left:16px; width:54px; height:70px; border-radius:4px;
    background:linear-gradient(180deg,#ffe8ab,#f6c86a); box-shadow:0 0 18px rgba(255,220,140,.6), inset 0 0 0 4px #6b4a2c;
    opacity:.85;
  }
  .char-scene::after{
    content:''; position:absolute; bottom:78px; right:14px; width:22px; height:34px; border-radius:50% 50% 4px 4px;
    background:#3f6b3f; box-shadow: -10px 6px 0 -4px #345a34, 9px 8px 0 -6px #345a34;
  }

  .char-figure{ position:absolute; bottom:0; left:50%; transform:translateX(-50%); width:190px; height:230px; z-index:2; }

  /* أرجل جالسة على الأرض */
  .char-legs{
    position:absolute; bottom:0; left:26px; width:138px; height:46px;
    background:#3d3226; border-radius:20px 20px 30px 30px;
  }
  .char-legs::before, .char-legs::after{
    content:''; position:absolute; bottom:4px; width:44px; height:26px; background:#2b2116; border-radius:16px;
  }
  .char-legs::before{ left:2px; transform:rotate(-6deg); }
  .char-legs::after{ right:2px; transform:rotate(6deg); }

  /* الجسد الجالس */
  .char-body{
    position:absolute; bottom:38px; left:38px; width:114px; height:112px; border-radius:50px 50px 20px 20px;
    background:var(--red);
  }
  .team-blue-scene .char-body{ background:var(--blue); }

  /* الرأس والوجه المبتسم */
  .char-head{
    position:absolute; top:2px; left:57px; width:76px; height:76px; border-radius:50%;
    background:#e3a878; box-shadow:inset -6px -6px 0 -34px rgba(0,0,0,.2); z-index:5;
  }
  .char-hair{ position:absolute; top:-8px; left:52px; width:86px; height:40px; border-radius:50% 50% 0 0; background:#4a3324; z-index:4; }
  .char-face{ position:absolute; top:0; left:0; width:100%; height:100%; }
  .eye{ position:absolute; top:32px; width:8px; height:10px; border-radius:50%; background:#2b2116; }
  .eye.l{ left:20px; } .eye.r{ left:48px; }
  .cheek{ position:absolute; top:44px; width:12px; height:8px; border-radius:50%; background:rgba(226,110,90,.55); }
  .cheek.l{ left:10px; } .cheek.r{ left:54px; }
  .smile{
    position:absolute; top:46px; left:22px; width:32px; height:16px;
    border-bottom:5px solid #7e2b26; border-radius:0 0 50% 50%;
  }

  /* الذراعان تحضنان الإطار */
  .char-arm{ position:absolute; bottom:60px; width:30px; height:70px; border-radius:16px; background:var(--red); z-index:6; }
  .team-blue-scene .char-arm{ background:var(--blue); }
  .char-arm.l{ left:10px; transform:rotate(28deg); }
  .char-arm.r{ right:10px; transform:rotate(-28deg); }

  /* إطار الصورة الكبير - هذا فقط ما يتم تكبيره عند الزوم */
  .held-frame-wrap{
    position:absolute; bottom:66px; left:50%; transform:translateX(-50%);
    z-index:7; transition: transform .1s ease-out;
  }
  .held-frame{
    width:200px; height:170px; background:#fff; border-radius:6px; padding:7px;
    box-shadow:0 14px 26px rgba(0,0,0,.5);
    display:flex; align-items:center; justify-content:center; overflow:hidden;
  }
  .held-frame img{ width:100%; height:100%; object-fit:cover; border-radius:3px; }
  .held-frame.locked{
    background:repeating-linear-gradient(135deg,#1c1712,#1c1712 8px,#241d15 8px,#241d15 16px);
    color:var(--gold); font-size:36px; align-items:center; justify-content:center;
  }

  .char-scene.mystery .char-body,
  .char-scene.mystery .char-arm{ background:#5a5044; filter:saturate(.4); }
  .char-scene.mystery .char-head{ background:#8a7a63; }
  .char-scene.mystery .eye,
  .char-scene.mystery .smile,
  .char-scene.mystery .cheek{ display:none; }

  .scene-caption{ text-align:center; font-family:'Rakkas'; font-size:13px; color:var(--ink-soft); margin-top:8px; }
  .scene-hint{ text-align:center; font-size:11px; color:var(--ink-soft); opacity:.75; margin-top:2px; }

  .scene-controls{ display:flex; align-items:center; justify-content:center; gap:8px; margin-top:8px; }
  .scene-controls .zoom-label{ font-size:12px; color:var(--ink-soft); white-space:nowrap; }
  .scene-controls input[type=range]{ width:130px; accent-color:var(--gold-dark); }

  .toolbar{ display:flex; gap:10px; justify-content:center; flex-wrap:wrap; margin-top:14px; }
  .toolbar button{ flex:1; min-width:130px; }

  .feature-status{ display:flex; justify-content:center; gap:10px; flex-wrap:wrap; margin-top:12px; }
  .feature-status span{
    font-size:12px; font-weight:700; padding:6px 12px; border-radius:16px;
    background:rgba(46,140,90,.14); color:#1e6b45; border:1.5px solid #2f9c63;
  }
  .feature-status span.used{
    background:rgba(193,68,60,.12); color:var(--red-dark); border-color:var(--red);
  }

  .admin-panel{ border:2px solid var(--gold); background:#fffaf0; }
  .admin-panel h4{ color:var(--gold-dark); }

  .modal-overlay{
    position:fixed; inset:0; background:rgba(10,7,3,.72); display:none; align-items:center; justify-content:center;
    z-index:999; padding:16px;
  }
  .modal-overlay.active{ display:flex; }
  .modal-box{
    background:var(--paper); border-radius:10px; max-width:440px; width:100%; padding:22px 20px;
    box-shadow:0 20px 50px rgba(0,0,0,.6); border:2px solid var(--gold-dark);
  }
  .modal-box h3{ color:var(--red-dark); font-size:22px; }
  .rules-list{ margin:12px 0; padding:0; list-style:none; font-size:14px; }
  .rules-list li{ padding:8px 0; border-bottom:1px dashed var(--paper-dark); display:flex; gap:8px; align-items:flex-start; }
  .rules-list li:last-child{ border-bottom:none; }
  .rules-list .num{ font-family:'Rakkas'; color:var(--red); min-width:22px; }
  .modal-check{ display:flex; align-items:center; gap:8px; font-size:12.5px; color:var(--ink-soft); margin:10px 0 16px; justify-content:flex-end;}

  .hint-alert{
    position:fixed; top:14px; left:50%; transform:translateX(-50%); z-index:1000;
    background:var(--gold); color:#2b2000; padding:12px 20px; border-radius:30px; font-weight:700;
    box-shadow:0 8px 20px rgba(0,0,0,.4); display:none; font-size:14px; max-width:90%; text-align:center;
  }
  .hint-alert.active{ display:block; animation: pop .25s ease; }
  .hint-alert.skip-style{ background:var(--red); color:#fff; }
  .hint-alert.own-style{ background:var(--ink); color:var(--gold); }
  @keyframes pop{ from{ transform:translateX(-50%) scale(.7); opacity:0;} to{ transform:translateX(-50%) scale(1); opacity:1;} }

  .small-note{ font-size:11.5px; color:var(--ink-soft); text-align:center; margin-top:6px;}

  .welcome-row{ display:flex; align-items:center; gap:8px; flex-wrap:wrap; }
</style>
</head>
<body>
<div class="wrap">
  <h1 class="case-title">🗂️ ملف القضية السرية</h1>
  <p class="case-sub">قائد ضد قائد • فريقك يساعدك على كشف الصورة الخفية</p>

  <div id="screenName" class="screen card active">
    <div class="pin"></div>
    <h3>مرحباً أيها المحقق 🕵️</h3>
    <p class="lead">قبل أن ندخل الملف، ما هو اسمك؟</p>
    <input type="text" id="playerNameInput" placeholder="اكتب اسمك هنا..." autocomplete="off" autofocus maxlength="20">
    <button class="btn-gold btn-block" onclick="submitName()">متابعة →</button>
  </div>

  <div id="screenLobby" class="screen">
    <div class="card tilt-l">
      <div class="pin"></div>
      <div class="welcome-row">
        <h3 id="welcomeMsg" style="color:var(--red-dark); margin-bottom:0;"></h3>
        <button type="button" class="btn-ghost btn-tiny" onclick="editName()">✏️ تعديل الاسم</button>
      </div>
      <p class="lead" style="margin-top:10px;">اختر الفريق الذي ستنضم إليه (٤ لاعبين كحد أقصى لكل فريق). أول من ينضم لفريقه يصبح <b>القائد 👑</b> وهو من يرفع الصورة السرية لفريقه، ولاحقاً هو فقط من يملك زر التلميح والتخطي.</p>

      <div class="team-picker">
        <div class="team-opt red" id="teamOptRed" onclick="chooseTeam('red')">🔴 الفريق الأحمر<small>انضم كعضو أو قائد</small></div>
        <div class="team-opt blue" id="teamOptBlue" onclick="chooseTeam('blue')">🔵 الفريق الأزرق<small>انضم كعضو أو قائد</small></div>
      </div>

      <div id="roomActionsBox" class="screen">
        <button class="btn-red btn-block" style="margin-bottom:8px;" onclick="createRoom()">🆕 إنشاء غرفة جديدة (ملف قضية جديد)</button>
        <hr class="divider">
        <p class="lead" style="margin-bottom:6px;">أو انضم إلى غرفة موجودة برمزها:</p>
        <input type="text" id="roomCodeInput" placeholder="رمز الغرفة..." maxlength="6" autocomplete="off">
        <button class="btn-ghost btn-block" onclick="joinRoomByInput()">🔑 انضمام للغرفة</button>
      </div>
    </div>

    <div id="roomInfoBox" class="screen card tilt-r">
      <div class="pin gold"></div>
      <p style="color:#1e6b45; font-weight:700; margin-bottom:10px;">📨 أرسل لكل صديق رابط فريقه — سينضم تلقائياً لهذا الفريق فور فتح الرابط وكتابة اسمه:</p>

      <div class="invite-block">
        <h4 class="red-label">🔴 رابط دعوة الفريق الأحمر</h4>
        <div class="link-box" id="inviteLinkRed"></div>
        <button class="btn-ghost btn-tiny" onclick="copyInvite('inviteLinkRed')">📋 نسخ رابط الأحمر</button>
      </div>
      <div class="invite-block">
        <h4 class="blue-label">🔵 رابط دعوة الفريق الأزرق</h4>
        <div class="link-box" id="inviteLinkBlue"></div>
        <button class="btn-ghost btn-tiny" onclick="copyInvite('inviteLinkBlue')">📋 نسخ رابط الأزرق</button>
      </div>

      <div style="text-align:center;">
        <span class="code-badge" id="displayCode"></span>
      </div>

      <div class="roster">
        <div class="side red">
          <h4>🔴 الفريق الأحمر</h4>
          <ul id="redRosterList"></ul>
        </div>
        <div class="side blue">
          <h4>🔵 الفريق الأزرق</h4>
          <ul id="blueRosterList"></ul>
        </div>
      </div>

      <div id="adminStartGameDiv" class="screen" style="margin-top:16px;">
        <button class="btn-gold btn-block" onclick="adminStartGame()" style="font-size:17px;">🚀 افتح الملف وابدأ التحدي</button>
        <p class="admin-only-note" style="margin-top:8px;">👑 بصفتك الأدمن (منشئ الغرفة)، أنت الوحيد القادر على بدء الجولات ومنح النقاط لاحقاً.</p>
      </div>
      <p id="roomStatusText" class="status-badge status-waiting">بانتظار اكتمال قادة الفريقين...</p>
    </div>
  </div>

  <div id="screenPrep" class="screen card">
    <div class="pin red"></div>
    <h3 id="prepHeaderTitle">📸 اختر الصورة السرية لفريقك</h3>
    <p class="lead" id="prepDescText">القائد فقط هو من يرفع الصورة، وستكون هذه هي الصورة التي سيحاول الفريق الخصم كشفها بالأسئلة.</p>

    <div id="captainUploadWrapper">
      <input type="file" id="imageInput" accept="image/*" style="width:100%; font-size:13px; margin-bottom:10px;">
      <div id="myPreviewWrap" style="text-align:center;">
        <div class="photo-frame screen" id="previewFrame" style="background:#fff; padding:8px 8px 26px; border-radius:4px; box-shadow:0 10px 18px rgba(0,0,0,.4); display:inline-block; max-width:100%;">
          <img id="mySecretPreview" src="" alt="" style="display:block; max-width:100%; max-height:230px; border-radius:2px; object-fit:contain; margin:0 auto; background:#eee;">
          <div class="cap" style="text-align:center; font-family:'Rakkas'; font-size:13px; color:#333; margin-top:6px;">صورتك السرية</div>
        </div>
      </div>
      <button id="lockImageBtn" class="btn-gold btn-block screen" style="margin-top:10px;" onclick="lockImage()">🔒 تثبيت الصورة والجاهزية</button>
    </div>
    <div id="memberWaitingNote" class="screen status-badge status-waiting">أنت عضو في الفريق — القائد هو من يرفع الصورة. انتظره قليلاً 🙂</div>

    <div style="margin-top:16px; display:flex; flex-direction:column; gap:8px;">
      <div id="redTeamStatusBadge" class="status-badge status-waiting">🔴 الفريق الأحمر: لم يرفع القائد الصورة بعد</div>
      <div id="blueTeamStatusBadge" class="status-badge status-waiting">🔵 الفريق الأزرق: لم يرفع القائد الصورة بعد</div>
    </div>
  </div>

  <div id="screenGame" class="screen">
    <div class="scoreboard">
      <div class="team-score">
        <b id="redScoreNum">0</b>
        <span class="name" id="redScoreName">الأحمر</span>
      </div>
      <div class="vs">VS</div>
      <div class="team-score">
        <b id="blueScoreNum">0</b>
        <span class="name" id="blueScoreName">الأزرق</span>
      </div>
    </div>

    <div class="card tilt-l" style="border-top:5px solid #2f9c63;">
      <div class="pin"></div>
      <h4 style="color:#1e6b45;">🖼️ صورة فريقكم لهذا الراوند</h4>
      <div class="scene-viewport">
        <div class="char-scene" id="mineScene">
          <div class="char-figure">
            <div class="char-legs"></div>
            <div class="char-arm l"></div>
            <div class="char-arm r"></div>
            <div class="char-body"></div>
            <div class="char-hair"></div>
            <div class="char-head">
              <div class="char-face">
                <div class="eye l"></div><div class="eye r"></div>
                <div class="cheek l"></div><div class="cheek r"></div>
                <div class="smile"></div>
              </div>
            </div>
          </div>
          <div class="held-frame-wrap" id="mineFrameWrap">
            <div class="held-frame" id="mineFrame"><img id="myActiveGameImage" src=""></div>
          </div>
        </div>
      </div>
      <div class="scene-controls">
        <span class="zoom-label">🔍 تكبير الصورة</span>
        <input type="range" min="1" max="2.2" step="0.05" value="1" oninput="mineSceneCtrl && mineSceneCtrl.setZoom(this.value)">
      </div>
      <p class="scene-caption">هذه صورتكم — الفريق الخصم يحاول تخمينها الآن</p>
      <p class="scene-hint">اسحب يمين/يسار لتدوير الرؤية، واستخدم الشريط لتكبير الصورة نفسها فقط</p>
    </div>

    <div class="card tilt-r" style="border-top:5px solid var(--gold-dark);">
      <div class="pin gold"></div>
      <h4 id="opponentTitleBox">🎁 الصورة السرية للخصم</h4>
      <div class="scene-viewport">
        <div class="char-scene mystery" id="oppScene">
          <div class="char-figure">
            <div class="char-legs"></div>
            <div class="char-arm l"></div>
            <div class="char-arm r"></div>
            <div class="char-body"></div>
            <div class="char-hair"></div>
            <div class="char-head">
              <div class="char-face">
                <div class="eye l"></div><div class="eye r"></div>
                <div class="cheek l"></div><div class="cheek r"></div>
                <div class="smile"></div>
              </div>
            </div>
          </div>
          <div class="held-frame-wrap" id="oppFrameWrap">
            <div class="held-frame locked" id="oppFrame">🔒</div>
          </div>
        </div>
      </div>
      <div class="scene-controls">
        <span class="zoom-label">🔍 تكبير الصورة</span>
        <input type="range" min="1" max="2.2" step="0.05" value="1" oninput="oppSceneCtrl && oppSceneCtrl.setZoom(this.value)">
      </div>
      <p class="scene-caption" id="oppCaption">🔒 مغلقة — اطرحوا أسئلة "نعم / لا" عبر المكالمة الصوتية لكشفها!</p>
      <p class="scene-hint">اسحب لتدوير زاوية النظر إلى الشخصية — الصورة تبقى مخفية حتى تُكشف</p>
    </div>

    <div id="gamePlayButtons" class="toolbar" style="display:none;">
      <button id="hintBtn" class="btn-gold" onclick="askHint()">💡 طلب تلميح (مرة واحدة)</button>
      <button id="skipBtn" class="btn-red" onclick="skipQuestion()">⏭️ تخطي / لا نريد الإجابة</button>
    </div>
    <p id="captainOnlyNote" class="small-note" style="display:none;">👑 هذان الزرّان يظهران فقط لقائد الفريق، ويُستخدمان مرة واحدة لكل جولة.</p>

    <div class="feature-status" id="featureStatusBox">
      <span id="hintStatusText">💡 التلميح: متاح</span>
      <span id="skipStatusText">⏭️ التخطي: متاح</span>
    </div>

    <div id="nextRoundBox" class="screen card">
      <button class="btn-gold btn-block" style="font-size:17px;" onclick="nextRoundPrep()">➡️ الانتقال للجولة التالية</button>
    </div>

    <div id="adminControls" class="screen card admin-panel">
      <h4>⚖️ لوحة تحكم الأدمن — من فاز بهذه الجولة؟</h4>
      <p class="admin-only-note">هذه اللوحة تظهر فقط لك بصفتك منشئ الغرفة، ولا يستطيع أي شخص آخر منح النقاط حتى لو حاول ذلك.</p>
      <div style="display:flex; flex-direction:column; gap:8px;">
        <button class="btn-red" id="winRedBtn" onclick="endRoundWithWinner('red')">نقطة للفريق الأحمر 🔴</button>
        <button class="btn-blue" id="winBlueBtn" onclick="endRoundWithWinner('blue')">نقطة للفريق الأزرق 🔵</button>
        <button class="btn-ghost" onclick="endRoundWithWinner('skip')">تخطي هذه الجولة (بدون فائز) ⏭️</button>
      </div>
    </div>
  </div>
</div>

<div class="hint-alert" id="hintAlert">🚨 الخصم يطلب منك تلميحاً شفهياً الآن عبر المكالمة!</div>
<div class="hint-alert skip-style" id="skipAlert">⏭️ الفريق الخصم لا يريد الإجابة على هذا السؤال، جرّبوا سؤالاً آخر!</div>
<div class="hint-alert own-style" id="ownTeamToast"></div>

<div class="modal-overlay" id="rulesModal">
  <div class="modal-box">
    <h3>📜 قوانين التحقيق</h3>
    <ul class="rules-list">
      <li><span class="num">١</span> كل صورة سرية يجب أن تُخمَّن بأسئلة "نعم / لا" فقط عبر المكالمة الصوتية — ممنوع ذكر اسم الشيء مباشرة.</li>
      <li><span class="num">٢</span> يُمنع تكرار نفس السؤال بصياغة مختلفة أكثر من مرة واحدة.</li>
      <li><span class="num">٣</span> كل فريق لديه تلميح واحد (💡) وتخطي واحد (⏭️) لكل جولة، ولا يستطيع استخدامهما إلا قائد الفريق.</li>
      <li><span class="num">٤</span> القائد فقط هو من يرفع صورة الفريق، لكن جميع الأعضاء يشاركون في طرح الأسئلة والتخمين.</li>
      <li><span class="num">٥</span> الأدمن (منشئ الغرفة) هو فقط من يقرر الفريق الفائز بكل جولة بعد التخمين الصحيح.</li>
    </ul>
    <label class="modal-check">
      <input type="checkbox" id="dontShowRulesAgain"> لا تُظهر هذه القوانين مجدداً في هذه الغرفة
      <span></span>
    </label>
    <button class="btn-gold btn-block" onclick="closeRulesModal()">فهمت، لنبدأ التحقيق 🔍</button>
  </div>
</div>

<script src="/socket.io/socket.io.js"></script>
<script>
  const socket = io();
  let myName = sessionStorage.getItem('game_name') || '';
  let currentRoom = sessionStorage.getItem('game_room') || '';
  let myTeam = sessionStorage.getItem('game_team') || '';
  let isAdmin = sessionStorage.getItem('game_admin') === 'true';
  let iAmCaptain = false;
  let myBase64Image = '';
  let opponentTeamSecretImg = '';
  let currentRoundNumber = 1;

  socket.on('connect', () => {
    if (myName && currentRoom && myTeam) {
      socket.emit('reconnect_player', { roomCode: currentRoom, playerName: myName, team: myTeam });
    }
  });

  function goScreen(id){
    document.querySelectorAll('.screen[id^="screen"]').forEach(s => s.classList.remove('active'));
    document.getElementById(id).classList.add('active');
  }

  if (myName) {
    document.getElementById('playerNameInput').value = myName;
    document.getElementById('welcomeMsg').innerText = `أهلاً بك أيها المحقق ${myName} 🕵️`;
    if (currentRoom && myTeam) {
      goScreen('screenLobby');
      showRoomInfoState();
    } else {
      goScreen('screenLobby');
    }
  }

  function submitName() {
    const val = document.getElementById('playerNameInput').value.trim();
    if (!val) { alert('الرجاء إدخال اسمك!'); return; }
    myName = val;
    sessionStorage.setItem('game_name', myName);
    document.getElementById('welcomeMsg').innerText = `أهلاً بك أيها المحقق ${myName} 🕵️`;
    goScreen('screenLobby');

    const urlParams = new URLSearchParams(window.location.search);
    const autoRoom = urlParams.get('room');
    const autoTeam = urlParams.get('team');

    if (autoRoom && (autoTeam === 'red' || autoTeam === 'blue')) {
      chooseTeam(autoTeam);
      document.getElementById('roomCodeInput').value = autoRoom;
      joinRoomByInput();
    } else if (autoRoom) {
      document.getElementById('roomCodeInput').value = autoRoom;
    }
  }

  document.getElementById('playerNameInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') { e.preventDefault(); submitName(); }
  });

  function editName() {
    const oldName = myName;
    const newName = prompt('اكتب اسمك الجديد:', myName || '');
    if (newName === null) return;
    const trimmed = newName.trim();
    if (!trimmed) { alert('الاسم لا يمكن أن يكون فارغاً!'); return; }
    myName = trimmed;
    sessionStorage.setItem('game_name', myName);
    document.getElementById('welcomeMsg').innerText = `أهلاً بك أيها المحقق ${myName} 🕵️`;
    const nameInput = document.getElementById('playerNameInput');
    if (nameInput) nameInput.value = myName;
    if (currentRoom && myTeam && oldName !== myName) {
      socket.emit('rename_player', { roomCode: currentRoom, oldName: oldName, newName: myName, team: myTeam });
    }
  }

  function chooseTeam(teamColor) {
    myTeam = teamColor;
    sessionStorage.setItem('game_team', myTeam);
    document.getElementById('teamOptRed').classList.toggle('selected', teamColor === 'red');
    document.getElementById('teamOptBlue').classList.toggle('selected', teamColor === 'blue');
    document.getElementById('roomActionsBox').classList.add('active');
  }

  function createRoom() {
    const code = Math.floor(10000 + Math.random() * 90000).toString();
    if (!myTeam) { alert('اختر فريقك أولاً!'); return; }
    isAdmin = true;
    sessionStorage.setItem('game_admin', 'true');
    currentRoom = code;
    sessionStorage.setItem('game_room', currentRoom);
    socket.emit('create_room', { roomCode: currentRoom, playerName: myName, team: myTeam });
  }

  function joinRoomByInput() {
    const code = document.getElementById('roomCodeInput').value.trim();
    if (!code) { alert('أدخل رمز الغرفة!'); return; }
    if (!myTeam) { alert('اختر فريقك أولاً!'); return; }
    currentRoom = code;
    sessionStorage.setItem('game_room', currentRoom);
    socket.emit('join_room', { roomCode: currentRoom, playerName: myName, team: myTeam });
  }

  socket.on('room_joined_successfully', (data) => {
    currentRoom = data.roomCode;
    sessionStorage.setItem('game_room', currentRoom);
    showRoomInfoState();
  });

  function showRoomInfoState() {
    document.getElementById('roomActionsBox').classList.remove('active');
    document.getElementById('roomInfoBox').classList.add('active');
    document.getElementById('displayCode').innerText = currentRoom;
    const base = window.location.origin + window.location.pathname;
    document.getElementById('inviteLinkRed').innerText = base + '?room=' + currentRoom + '&team=red';
    document.getElementById('inviteLinkBlue').innerText = base + '?room=' + currentRoom + '&team=blue';
    if (isAdmin) document.getElementById('adminStartGameDiv').classList.add('active');
  }

  function copyInvite(elId) {
    const text = document.getElementById(elId).innerText;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(() => alert('تم نسخ الرابط ✅')).catch(() => alert('انسخ الرابط يدوياً من الصندوق'));
    } else {
      alert('انسخ الرابط يدوياً من الصندوق');
    }
  }

  function adminStartGame() {
    socket.emit('admin_trigger_start', { roomCode: currentRoom });
  }

  socket.on('error_msg', (m) => alert(m));

  socket.on('update_room_state', (state) => {
    const players = state.players || {};
    const redList = Object.values(players).filter(p => p.team === 'red');
    const blueList = Object.values(players).filter(p => p.team === 'blue');

    const me = Object.values(players).find(p => p.name === myName && p.team === myTeam);
    iAmCaptain = !!(me && me.isCaptain);
    updateCaptainOnlyUI();

    document.getElementById('redRosterList').innerHTML =
      renderRoster(redList) + emptySlots(redList.length);
    document.getElementById('blueRosterList').innerHTML =
      renderRoster(blueList) + emptySlots(blueList.length);

    document.getElementById('redScoreName').innerText = state.redLeaderName ? `الأحمر (${state.redLeaderName})` : 'الأحمر';
    document.getElementById('blueScoreName').innerText = state.blueLeaderName ? `الأزرق (${state.blueLeaderName})` : 'الأزرق';

    if (state.redLeaderName && state.blueLeaderName) {
      document.getElementById('roomStatusText').innerText = 'القائدان جاهزان — يمكن للأدمن بدء التحقيق!';
      document.getElementById('roomStatusText').className = 'status-badge status-ready';
    } else {
      document.getElementById('roomStatusText').innerText = 'بانتظار اكتمال قادة الفريقين...';
      document.getElementById('roomStatusText').className = 'status-badge status-waiting';
    }
  });

  function renderRoster(list) {
    return list.map(p => `<li class="${p.isCaptain ? 'captain' : ''}">${p.name}</li>`).join('');
  }
  function emptySlots(count) {
    let s = '';
    for (let i = count; i < 4; i++) s += `<li class="empty-slot">— مقعد شاغر —</li>`;
    return s;
  }

  function updateCaptainOnlyUI() {
    const toolbar = document.getElementById('gamePlayButtons');
    const note = document.getElementById('captainOnlyNote');
    if (iAmCaptain) {
      toolbar.style.display = 'flex';
      note.style.display = 'block';
    } else {
      toolbar.style.display = 'none';
      note.style.display = 'none';
    }
  }

  socket.on('force_go_to_prep', (data) => {
    currentRoundNumber = data.roundNumber;
    goToPrep();
  });

  function goToPrep() {
    goScreen('screenPrep');
    document.getElementById('prepHeaderTitle').innerText = `📸 اختر الصورة السرية لفريقك (الجولة ${currentRoundNumber})`;

    const captainWrap = document.getElementById('captainUploadWrapper');
    const memberNote = document.getElementById('memberWaitingNote');
    if (iAmCaptain) {
      captainWrap.style.display = 'block';
      memberNote.classList.remove('active');
    } else {
      captainWrap.style.display = 'none';
      memberNote.classList.add('active');
    }

    document.getElementById('previewFrame').classList.remove('active');
    document.getElementById('lockImageBtn').classList.remove('active');
    document.getElementById('imageInput').value = '';
    document.getElementById('prepDescText').innerText = 'القائد فقط هو من يرفع الصورة، وستكون هذه هي الصورة التي سيحاول الفريق الخصم كشفها بالأسئلة.';
    myBase64Image = '';

    opponentTeamSecretImg = '';
    document.getElementById('myActiveGameImage').src = '';
    const oppScene = document.getElementById('oppScene');
    const oppFrame = document.getElementById('oppFrame');
    oppScene.classList.add('mystery');
    oppScene.classList.remove('team-blue-scene');
    oppFrame.classList.add('locked');
    oppFrame.innerHTML = '🔒';
    document.getElementById('oppCaption').innerText = '🔒 مغلقة — اطرحوا أسئلة "نعم / لا" عبر المكالمة الصوتية لكشفها!';

    updatePrepStatusUI({ redReady: false, blueReady: false });
  }

  document.getElementById('imageInput').addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (file) {
      const reader = new FileReader();
      reader.onload = (evt) => {
        myBase64Image = evt.target.result;
        document.getElementById('mySecretPreview').src = myBase64Image;
        document.getElementById('previewFrame').classList.add('active');
        document.getElementById('lockImageBtn').classList.add('active');
      };
      reader.readAsDataURL(file);
    }
  });

  function lockImage() {
    if (!myBase64Image) { alert('اختر صورة أولاً!'); return; }
    document.getElementById('lockImageBtn').classList.remove('active');
    document.getElementById('captainUploadWrapper').style.display = 'none';
    document.getElementById('prepDescText').innerText = '✓ تم تثبيت صورة فريقكم بنجاح. بانتظار الفريق الآخر...';
    socket.emit('team_image_ready', { roomCode: currentRoom, team: myTeam, image: myBase64Image });
  }

  socket.on('prep_status_update', (status) => updatePrepStatusUI(status));

  function updatePrepStatusUI(status) {
    const redBadge = document.getElementById('redTeamStatusBadge');
    const blueBadge = document.getElementById('blueTeamStatusBadge');
    redBadge.innerText = status.redReady ? '🔴 الفريق الأحمر: جاهز ✓' : '🔴 الفريق الأحمر: لم يرفع القائد الصورة بعد';
    redBadge.className = 'status-badge ' + (status.redReady ? 'status-ready' : 'status-waiting');
    blueBadge.innerText = status.blueReady ? '🔵 الفريق الأزرق: جاهز ✓' : '🔵 الفريق الأزرق: لم يرفع القائد الصورة بعد';
    blueBadge.className = 'status-badge ' + (status.blueReady ? 'status-ready' : 'status-waiting');
  }

  // الدوران يُطبَّق على كامل المشهد، والزوم يُطبَّق فقط على إطار الصورة (held-frame-wrap)
  function enableSceneInteraction(sceneEl) {
    const frameWrap = sceneEl.querySelector('.held-frame-wrap');
    let rotY = 0, zoom = 1, dragging = false, startX = 0, startRot = 0;

    function apply() {
      sceneEl.style.transform = `rotateY(${rotY}deg)`;
      frameWrap.style.transform = `translateX(-50%) scale(${zoom})`;
    }

    function down(clientX, pointerId) {
      dragging = true; startX = clientX; startRot = rotY;
      if (pointerId !== undefined && sceneEl.setPointerCapture) {
        try { sceneEl.setPointerCapture(pointerId); } catch (e) {}
      }
    }
    function move(clientX) {
      if (!dragging) return;
      const dx = clientX - startX;
      rotY = Math.max(-22, Math.min(22, startRot + dx / 4));
      apply();
    }
    function up() { dragging = false; }

    sceneEl.addEventListener('pointerdown', (e) => down(e.clientX, e.pointerId));
    sceneEl.addEventListener('pointermove', (e) => move(e.clientX));
    sceneEl.addEventListener('pointerup', up);
    sceneEl.addEventListener('pointerleave', up);
    sceneEl.addEventListener('pointercancel', up);

    sceneEl.addEventListener('wheel', (e) => {
      e.preventDefault();
      zoom = Math.max(1, Math.min(2.2, zoom + (e.deltaY < 0 ? 0.05 : -0.05)));
      apply();
    }, { passive: false });

    apply();

    return {
      setZoom(z) { zoom = parseFloat(z); apply(); },
      reset() { rotY = 0; zoom = 1; apply(); }
    };
  }

  const mineSceneCtrl = enableSceneInteraction(document.getElementById('mineScene'));
  const oppSceneCtrl = enableSceneInteraction(document.getElementById('oppScene'));

  socket.on('start_game_round', (data) => {
    goScreen('screenGame');
    currentRoundNumber = data.roundNumber;

    updateCaptainOnlyUI();
    document.getElementById('hintBtn').disabled = false;
    document.getElementById('skipBtn').disabled = false;
    document.getElementById('hintBtn').innerText = '💡 طلب تلميح (مرة واحدة)';
    document.getElementById('skipBtn').innerText = '⏭️ تخطي / لا نريد الإجابة';

    document.getElementById('nextRoundBox').classList.remove('active');

    mineSceneCtrl.reset();
    oppSceneCtrl.reset();

    opponentTeamSecretImg = '';
    const oppScene = document.getElementById('oppScene');
    const oppFrame = document.getElementById('oppFrame');
    oppScene.classList.add('mystery');
    oppFrame.classList.add('locked');
    oppFrame.innerHTML = '🔒';
    document.getElementById('oppCaption').innerText = '🔒 مغلقة — اطرحوا أسئلة "نعم / لا" عبر المكالمة الصوتية لكشفها!';

    const mineScene = document.getElementById('mineScene');
    mineScene.classList.toggle('team-blue-scene', myTeam === 'blue');

    if (myTeam === 'red') {
      document.getElementById('myActiveGameImage').src = data.redImage;
      opponentTeamSecretImg = data.blueImage;
      document.getElementById('opponentTitleBox').innerText = `🎁 الصورة السرية للفريق الأزرق (الراوند ${data.roundNumber})`;
    } else {
      document.getElementById('myActiveGameImage').src = data.blueImage;
      opponentTeamSecretImg = data.redImage;
      document.getElementById('opponentTitleBox').innerText = `🎁 الصورة السرية للفريق الأحمر (الراوند ${data.roundNumber})`;
    }

    document.getElementById('redScoreName').innerText = data.redLeaderName ? `الأحمر (${data.redLeaderName})` : 'الأحمر';
    document.getElementById('blueScoreName').innerText = data.blueLeaderName ? `الأزرق (${data.blueLeaderName})` : 'الأزرق';

    if (isAdmin) {
      document.getElementById('adminControls').classList.add('active');
      document.getElementById('winRedBtn').innerText = `نقطة للفريق الأحمر (${data.redLeaderName || 'الأحمر'}) 🔴`;
      document.getElementById('winBlueBtn').innerText = `نقطة للفريق الأزرق (${data.blueLeaderName || 'الأزرق'}) 🔵`;
    }

    maybeShowRules();
  });

  function maybeShowRules() {
    const key = 'rules_hidden_' + currentRoom;
    if (localStorage.getItem(key) === 'true') return;
    document.getElementById('rulesModal').classList.add('active');
  }
  function closeRulesModal() {
    if (document.getElementById('dontShowRulesAgain').checked) {
      localStorage.setItem('rules_hidden_' + currentRoom, 'true');
    }
    document.getElementById('rulesModal').classList.remove('active');
  }

  function showOwnTeamToast(msg) {
    const el = document.getElementById('ownTeamToast');
    el.innerText = msg;
    el.classList.add('active');
    setTimeout(() => el.classList.remove('active'), 3500);
  }

  function askHint() { socket.emit('request_hint', { roomCode: currentRoom, team: myTeam }); }
  function skipQuestion() { socket.emit('skip_question', { roomCode: currentRoom, team: myTeam }); }

  // تحديث حالة التلميح/التخطي لكل الفريقين (يصل الجميع، ونعرض حالة فريقنا فقط)
  socket.on('feature_status_update', (data) => {
    if (!myTeam) return;
    const hintUsed = data.hintUsed ? data.hintUsed[myTeam] : false;
    const skipUsed = data.skipUsed ? data.skipUsed[myTeam] : false;

    const hintText = document.getElementById('hintStatusText');
    const skipText = document.getElementById('skipStatusText');
    hintText.innerText = hintUsed ? '💡 التلميح: تم استخدامه' : '💡 التلميح: متاح';
    hintText.className = hintUsed ? 'used' : '';
    skipText.innerText = skipUsed ? '⏭️ التخطي: تم استخدامه' : '⏭️ التخطي: متاح';
    skipText.className = skipUsed ? 'used' : '';

    if (iAmCaptain) {
      document.getElementById('hintBtn').disabled = !!hintUsed;
      document.getElementById('hintBtn').innerText = hintUsed ? '💡 تم استخدام التلميح' : '💡 طلب تلميح (مرة واحدة)';
      document.getElementById('skipBtn').disabled = !!skipUsed;
      document.getElementById('skipBtn').innerText = skipUsed ? '⏭️ تم التخطي' : '⏭️ تخطي / لا نريد الإجابة';
    }
  });

  socket.on('notify_hint_requested', (data) => {
    if (!data) return;
    if (data.fromTeam === myTeam) {
      showOwnTeamToast('💡 استخدم قائد فريقكم ميزة التلميح لهذه الجولة.');
    } else if (data.toTeam === myTeam) {
      const el = document.getElementById('hintAlert');
      el.classList.add('active');
      setTimeout(() => el.classList.remove('active'), 4000);
    }
  });

  socket.on('notify_skip_requested', (data) => {
    if (!data) return;
    if (data.fromTeam === myTeam) {
      showOwnTeamToast('⏭️ استخدم قائد فريقكم ميزة التخطي لهذا السؤال.');
    } else if (data.toTeam === myTeam) {
      const el = document.getElementById('skipAlert');
      el.classList.add('active');
      setTimeout(() => el.classList.remove('active'), 4000);
    }
  });

  window.endRoundWithWinner = function (winnerTeam) {
    socket.emit('end_round', { roomCode: currentRoom, winnerTeam });
  };

  socket.on('round_ended', (data) => {
    document.getElementById('redScoreNum').innerText = data.scores.red;
    document.getElementById('blueScoreNum').innerText = data.scores.blue;
    document.getElementById('redScoreName').innerText = data.redLeaderName ? `الأحمر (${data.redLeaderName})` : 'الأحمر';
    document.getElementById('blueScoreName').innerText = data.blueLeaderName ? `الأزرق (${data.blueLeaderName})` : 'الأزرق';

    const oppScene = document.getElementById('oppScene');
    const oppFrame = document.getElementById('oppFrame');
    oppScene.classList.toggle('team-blue-scene', myTeam === 'red');
    oppScene.classList.remove('mystery');
    oppFrame.classList.remove('locked');
    oppFrame.innerHTML = `<img src="${opponentTeamSecretImg}">`;
    document.getElementById('oppCaption').innerText = '✅ تم الكشف عن الصورة!';

    if (isAdmin) document.getElementById('adminControls').classList.remove('active');
    document.getElementById('gamePlayButtons').style.display = 'none';
    document.getElementById('captainOnlyNote').style.display = 'none';
    document.getElementById('nextRoundBox').classList.add('active');
  });

  function nextRoundPrep() { socket.emit('next_round_prep', { roomCode: currentRoom }); }
</script>
</body>
</html>
HTMLEOF



npm install
node server.js
