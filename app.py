from flask import Flask, render_template
import os
import socket
import random

app = Flask(__name__)

@app.route("/")
def hello():
    if random.random() < 0.9:
        return "Internal Server Error", 500
    hostname = socket.gethostname()[:12]
    return render_template("index.html", message=f"CloudWatch alarm test new - Task: {hostname}")

@app.route("/health")
def health():
    return "SUCCESS", 200  # 헬스체크는 통과 (배포 성공 → Bake Time 진입)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
