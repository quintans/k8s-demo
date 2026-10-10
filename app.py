import os

from flask import Flask, jsonify

app = Flask(__name__)

VERSION = os.getenv("APP_VERSION", "local")


@app.get("/")
def index():
    return jsonify(
        application="k8s-demo",
        version=VERSION,
        message="Hello from Kubernetes!"
    )


@app.get("/healthz")
def health():
    return "", 200


@app.get("/readyz")
def ready():
    return "", 200