```python
#!/usr/bin/env python3
import argparse
import yaml
import os

# Service criticality and resource weights
SERVICE_WEIGHTS = {
    # Critical services (always running)
    'postgres': {'priority': 5, 'cpu_weight': 0.15, 'ram_weight': 0.15},
    'redis': {'priority': 5, 'cpu_weight': 0.05, 'ram_weight': 0.03},
    'caddy': {'priority': 5, 'cpu_weight': 0.05, 'ram_weight': 0.02},
    'cloudflare-tunnel': {'priority': 5, 'cpu_weight': 0.02, 'ram_weight': 0.01},
    
    # Primary services
    'n8n': {'priority': 4, 'cpu_weight': 0.2, 'ram_weight': 0.15},
    'n8n-worker': {'priority': 4, 'cpu_weight': 0.15, 'ram_weight': 0.1},
    'flowise': {'priority': 4, 'cpu_weight': 0.15, 'ram_weight': 0.12},
    'open-webui': {'priority': 4, 'cpu_weight': 0.1, 'ram_weight': 0.08},
    'dify': {'priority': 4, 'cpu_weight': 0.2, 'ram_weight': 0.2},
    
    # Heavy AI/ML services
    'ollama': {'priority': 3, 'cpu_weight': 0.3, 'ram_weight': 0.35},
    'comfyui': {'priority': 3, 'cpu_weight': 0.25, 'ram_weight': 0.3},
    'libretranslate': {'priority': 3, 'cpu_weight': 0.2, 'ram_weight': 0.15},
    'langfuse': {'priority': 3, 'cpu_weight': 0.1, 'ram_weight': 0.1},
    'letta': {'priority': 3, 'cpu_weight': 0.15, 'ram_weight': 0.12},
    'ragapp': {'priority': 3, 'cpu_weight': 0.1, 'ram_weight': 0.1},
    
    # Database/Storage services
    'qdrant': {'priority': 2, 'cpu_weight': 0.1, 'ram_weight': 0.15},
    'neo4j': {'priority': 2, 'cpu_weight': 0.1, 'ram_weight': 0.15},
    'weaviate': {'priority': 2, 'cpu_weight': 0.1, 'ram_weight': 0.15},
    'clickhouse': {'priority': 3, 'cpu_weight': 0.15, 'ram_weight': 0.2},
    'minio': {'priority': 3, 'cpu_weight': 0.1, 'ram_weight': 0.1},
    'valkey': {'priority': 3, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    
    # Standard services
    'crawl4ai': {'priority': 2, 'cpu_weight': 0.1, 'ram_weight': 0.08},
    'paddleocr': {'priority': 2, 'cpu_weight': 0.15, 'ram_weight': 0.1},
    'paddlex': {'priority': 2, 'cpu_weight': 0.15, 'ram_weight': 0.1},
    'postiz': {'priority': 2, 'cpu_weight': 0.1, 'ram_weight': 0.08},
    'postgresus': {'priority': 2, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    
    # Light services
    'searxng': {'priority': 1, 'cpu_weight': 0.05, 'ram_weight': 0.03},
    'portainer': {'priority': 1, 'cpu_weight': 0.03, 'ram_weight': 0.02},
    'prometheus': {'priority': 1, 'cpu_weight': 0.05, 'ram_weight': 0.03},
    'grafana': {'priority': 1, 'cpu_weight': 0.05, 'ram_weight': 0.03},
    'python-runner': {'priority': 1, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    
    # Supabase services (if enabled)
    'supabase-postgres': {'priority': 4, 'cpu_weight': 0.15, 'ram_weight': 0.15},
    'supabase-kong': {'priority': 4, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-auth': {'priority': 4, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-storage': {'priority': 3, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-realtime': {'priority': 3, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-meta': {'priority': 2, 'cpu_weight': 0.03, 'ram_weight': 0.03},
    'supabase-studio': {'priority': 2, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-edge-functions': {'priority': 3, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-analytics': {'priority': 2, 'cpu_weight': 0.05, 'ram_weight': 0.05},
    'supabase-vector': {'priority': 2, 'cpu_weight': 0.03, 'ram_weight': 0.03},
}

def calculate_resources(cores, ram_gb, enabled_services):
    """Calculate resource allocations based on enabled services."""
    
    # Filter to only enabled services
    active_services = {}
    profiles = enabled_services.lower().split(',')
    
    for service, weights in SERVICE_WEIGHTS.items():
        # Check if service matches any enabled profile
        for profile in profiles:
            if service.replace('-', '').lower() in profile.replace('-', '') or \
               profile.replace('-', '') in service.replace('-', '').lower():
                active_services[service] = weights
                break
    
    if not active_services:
        # Default to critical services only
        active_services = {k: v for k, v in SERVICE_WEIGHTS.items() 
                         if v['priority'] == 5}
    
    # Normalize weights
    total_cpu_weight = sum(s['cpu_weight'] for s in active_services.values())
    total_ram_weight = sum(s['ram_weight'] for s in active_services.values())
    
    if total_cpu_weight == 0:
        total_cpu_weight = 1
    if total_ram_weight == 0:
        total_ram_weight = 1
    
    allocations = {}
    for service, weights in active_services.items():
        cpu_allocation = cores * (weights['cpu_weight'] / total_cpu_weight)
        ram_allocation = ram_gb * (weights['ram_weight'] / total_ram_weight)
        
        allocations[service] = {
            'cpu_limit': round(cpu_allocation, 2),
            'cpu_reservation': round(cpu_allocation * 0.25, 2),  # 25% reservation
            'ram_limit_gb': round(ram_allocation, 1),
            'ram_reservation_gb': round(ram_allocation * 0.3, 1)  # 30% reservation
        }
    
    return allocations

def generate_override_yaml(allocations):
    """Generate docker-compose.override.yml content."""
    
    override = {'version': '3.8', 'services': {}}
    
    for service, resources in allocations.items():
        override['services'][service] = {
            'deploy': {
                'resources': {
                    'limits': {
                        'cpus': str(resources['cpu_limit']),
                        'memory': f"{resources['ram_limit_gb']}G"
                    },
                    'reservations': {
                        'cpus': str(max(0.05, resources['cpu_reservation'])),  # Min 0.05
                        'memory': f"{max(64, int(resources['ram_reservation_gb'] * 1024))}M"
                    }
                }
            }
        }
    
    return yaml.dump(override, default_flow_style=False, sort_keys=False)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cores', type=float, required=True)
    parser.add_argument('--ram', type=float, required=True)
    parser.add_argument('--profiles', type=str, required=True)
    parser.add_argument('--output', type=str, default='docker-compose.override.yml')
    
    args = parser.parse_args()
    
    allocations = calculate_resources(args.cores, args.ram, args.profiles)
    yaml_content = generate_override_yaml(allocations)
    
    with open(args.output, 'w') as f:
        f.write(yaml_content)
    
    print(f"Generated {args.output} with resource limits for {len(allocations)} services")

if __name__ == '__main__':
    main()
```