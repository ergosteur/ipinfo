FROM python:3.11-slim

# Create a non-root user and group
RUN groupadd -r ipinfo && useradd -r -g ipinfo ipinfo

WORKDIR /srv/ipinfo

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Change ownership of the application directory to the non-root user
RUN chown -R ipinfo:ipinfo /srv/ipinfo

# Switch to the non-root user
USER ipinfo

EXPOSE 8000

CMD ["gunicorn", "-w", "3", "-b", "0.0.0.0:8000", "app:app"]