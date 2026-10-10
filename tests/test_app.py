from app import app


def test_index():
    client = app.test_client()

    response = client.get("/")

    assert response.status_code == 200
    assert response.json["application"] == "k8s-demo"


def test_health():
    response = app.test_client().get("/healthz")

    assert response.status_code == 200