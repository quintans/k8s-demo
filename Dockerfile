FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=local

WORKDIR /app

RUN addgroup --system app \
    && adduser --system --ingroup app app

COPY requirements.txt .
# Install the app dependencies, then remove pip itself: it is not needed at
# runtime and its vendored libraries (urllib3, msgpack, setuptools, ...) show
# up as vulnerabilities in image scans.
RUN pip install --no-cache-dir -r requirements.txt \
    && pip uninstall -y pip

COPY app.py .

USER app

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", \
     "--workers", "2", "--access-logfile", "-", "app:app"]