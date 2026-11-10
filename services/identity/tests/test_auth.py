PASSWORD = "correct horse battery staple"


def test_health(client):
    assert client.get("/health").json()["status"] == "ok"
    assert client.get("/api/auth/health").json()["db"] == "ok"


def test_register_login_me_logout(client, email):
    r = client.post("/api/auth/register", json={"email": email.upper(), "display_name": "Ada", "password": PASSWORD})
    assert r.status_code == 201, r.text
    assert r.json()["email"] == email  # normalised to lower-case
    cookie = r.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie and "path=/api" in cookie

    client.cookies.clear()
    r = client.post("/api/auth/login", json={"email": email, "password": PASSWORD})
    assert r.status_code == 200
    me = client.get("/api/auth/me")
    assert me.status_code == 200 and me.json()["display_name"] == "Ada"

    client.post("/api/auth/logout")
    client.cookies.clear()
    assert client.get("/api/auth/me").status_code == 401


def test_duplicate_email_rejected(client, email):
    body = {"email": email, "display_name": "A", "password": PASSWORD}
    assert client.post("/api/auth/register", json=body).status_code == 201
    assert client.post("/api/auth/register", json=body).status_code == 409


def test_weak_password_rejected(client, email):
    r = client.post("/api/auth/register", json={"email": email, "display_name": "A", "password": "short"})
    assert r.status_code == 422


def test_same_error_for_unknown_user_and_bad_password(client, email):
    client.post("/api/auth/register", json={"email": email, "display_name": "A", "password": PASSWORD})
    a = client.post("/api/auth/login", json={"email": email, "password": "wrong-password!!"})
    b = client.post("/api/auth/login", json={"email": "nobody-" + email, "password": "wrong-password!!"})
    assert a.status_code == b.status_code == 401
    assert a.json() == b.json()


def test_login_rate_limited(client, email):
    for _ in range(5):
        client.post("/api/auth/login", json={"email": email, "password": "wrong-password!!"})
    r = client.post("/api/auth/login", json={"email": email, "password": "wrong-password!!"})
    assert r.status_code == 429


def test_tampered_token_rejected(client):
    client.cookies.clear()
    r = client.get("/api/auth/me", headers={"Authorization": "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0."})
    assert r.status_code == 401
