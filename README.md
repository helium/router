# Router

## Docker

### Commands

```
# Build
sudo docker-compose build --force-rm

# Up
sudo docker-compose up -d

# Down
sudo docker-compose down

# Tail logs
sudo docker-compose logs -f --tail=20

# Get in container
sudo docker exec -it helium_router bash
```

### Data

Data is located in `/var/data`.

### Config

Config is in `.env`.
