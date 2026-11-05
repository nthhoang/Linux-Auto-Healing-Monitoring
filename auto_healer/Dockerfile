FROM python:3.11-alpine

WORKDIR /app

# Cài đặt curl và thư viện cần thiết
RUN apk add --no-cache curl bash

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5001

CMD ["python", "-u", "app.py"]
