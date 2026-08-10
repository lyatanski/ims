FROM alpine:latest
RUN apk add --no-cache python3
COPY trace.py /trace.py
ENTRYPOINT ["python3", "-u", "/trace.py"]
