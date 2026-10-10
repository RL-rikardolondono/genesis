// Genesis: recuperación de contraseña ("¿Olvidó su contraseña?")
var AUTH = 'https://ep-weathered-breeze-b4c82o4u.neonauth.c-6.us-east-2.aws.neon.tech/neondb/auth';
var VOLVER = location.origin + location.pathname;
var MARCA = '<div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Genesis</span></div>';

function caja(html) {
  var a = document.getElementById('auth');
  a.hidden = false;
  document.getElementById('app').hidden = true;
  a.innerHTML = '<div class="auth-box">' + MARCA + html + '</div>';
}
function irInicio() { location.href = VOLVER; }

async function post(ruta, datos) {
  var r = await fetch(AUTH + ruta, { method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify(datos) });
  var j = await r.json().catch(function () { return {}; });
  if (!r.ok) throw new Error(j.message || 'No se pudo completar la solicitud');
  return j;
}

function pedirEnlace() {
  caja('<h2>Recuperar contraseña</h2>' +
    '<p class="muted">Escriba el correo con el que se registró. Le enviaremos un enlace para crear una contraseña nueva.</p>' +
    '<form id="fOlv"><label class="field"><span>Correo electrónico</span><input id="oEmail" type="email" required></label>' +
    '<p class="err" id="oErr" role="alert"></p><button class="btn" type="submit">Enviar enlace</button></form>' +
    '<p class="muted" style="margin-top:14px"><button class="linkbtn" type="button" id="bVolver">Volver a iniciar sesión</button></p>');
  document.getElementById('bVolver').onclick = irInicio;
  document.getElementById('oEmail').focus();
  document.getElementById('fOlv').onsubmit = async function (e) {
    e.preventDefault();
    var b = e.target.querySelector('.btn');
    b.disabled = true; b.textContent = 'Enviando…';
    try {
      await post('/request-password-reset', { email: document.getElementById('oEmail').value.trim(), redirectTo: VOLVER });
      caja('<h2>Revise su correo</h2><p>Si el correo está registrado en Genesis, en unos minutos le llegará un mensaje con el enlace para crear una contraseña nueva. Revise también la carpeta de correo no deseado.</p>' +
        '<p class="muted">El enlace vence en una hora.</p><button class="btn" type="button" id="bVolver">Volver a iniciar sesión</button>');
      document.getElementById('bVolver').onclick = irInicio;
    } catch (err) {
      document.getElementById('oErr').textContent = err.message;
      b.disabled = false; b.textContent = 'Enviar enlace';
    }
  };
}

function nuevaClave(token) {
  caja('<h2>Nueva contraseña</h2>' +
    '<form id="fNue"><label class="field"><span>Contraseña nueva (mínimo 8 caracteres)</span><input id="n1" type="password" minlength="8" autocomplete="new-password" required></label>' +
    '<label class="field"><span>Repita la contraseña</span><input id="n2" type="password" minlength="8" autocomplete="new-password" required></label>' +
    '<p class="err" id="nErr" role="alert"></p><button class="btn" type="submit">Guardar contraseña</button></form>');
  document.getElementById('n1').focus();
  document.getElementById('fNue').onsubmit = async function (e) {
    e.preventDefault();
    var p1 = document.getElementById('n1').value, p2 = document.getElementById('n2').value;
    if (p1 !== p2) { document.getElementById('nErr').textContent = 'Las contraseñas no coinciden'; return; }
    var b = e.target.querySelector('.btn');
    b.disabled = true; b.textContent = 'Guardando…';
    try {
      await post('/reset-password', { newPassword: p1, token: token });
      history.replaceState(null, '', VOLVER);
      caja('<h2>Contraseña actualizada</h2><p>Ya puede iniciar sesión con su contraseña nueva.</p><button class="btn" type="button" id="bVolver">Iniciar sesión</button>');
      document.getElementById('bVolver').onclick = irInicio;
    } catch (err) {
      document.getElementById('nErr').textContent = err.message;
      b.disabled = false; b.textContent = 'Guardar contraseña';
    }
  };
}

var parametros = new URLSearchParams(location.search);
if (parametros.get('token')) {
  nuevaClave(parametros.get('token'));
} else if (parametros.get('error')) {
  history.replaceState(null, '', VOLVER);
  caja('<h2>Enlace vencido</h2><p>El enlace para cambiar la contraseña ya no es válido. Pida uno nuevo.</p><button class="btn" type="button" id="bOtra">Pedir otro enlace</button>');
  document.getElementById('bOtra').onclick = pedirEnlace;
} else {
  // Agrega "¿Olvidó su contraseña?" a la pantalla de inicio de sesión
  new MutationObserver(function () {
    var f = document.querySelector('#auth form');
    if (!f || !document.getElementById('lPass') || document.getElementById('lOlv')) return;
    var p = document.createElement('p');
    p.id = 'lOlv'; p.style.margin = '0';
    p.innerHTML = '<button class="linkbtn" type="button">¿Olvidó su contraseña?</button>';
    p.querySelector('button').onclick = pedirEnlace;
    f.appendChild(p);
  }).observe(document.getElementById('auth'), { childList: true, subtree: true });
}
