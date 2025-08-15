#!/usr/bin/env python3
"""
Render Jinja2 templates to Kubernetes manifests
"""

import os
import sys
import yaml
import argparse
import base64
from pathlib import Path
from jinja2 import Environment, FileSystemLoader, select_autoescape

def load_values(environment):
    """Load values for the specified environment"""
    values_file = Path(f"kubernetes/values/{environment}.yaml")
    if not values_file.exists():
        print(f"Error: Values file not found: {values_file}")
        sys.exit(1)
    
    with open(values_file, 'r') as f:
        values = yaml.safe_load(f)
    
    # Add base64 encoding filter
    values['b64encode'] = lambda s: base64.b64encode(s.encode()).decode()
    
    return values

def render_template(template_env, template_name, context, output_dir):
    """Render a single template"""
    template = template_env.get_template(template_name)
    rendered = template.render(**context)
    
    # Determine output filename
    output_name = template_name.replace('.j2', '.yaml')
    if 'service_name' in context:
        output_name = f"{context['service_name']}-{output_name}"
    
    output_path = output_dir / output_name
    
    with open(output_path, 'w') as f:
        f.write(rendered)
    
    print(f"  ✓ Rendered {template_name} -> {output_path}")
    return output_path

def main():
    parser = argparse.ArgumentParser(description='Render Kubernetes manifests from Jinja2 templates')
    parser.add_argument('--environment', '-e', required=True, 
                      choices=['dev', 'staging', 'prod'],
                      help='Environment to render manifests for')
    parser.add_argument('--output-dir', '-o', default='kubernetes/rendered',
                      help='Output directory for rendered manifests')
    
    args = parser.parse_args()
    
    # Create output directory
    output_dir = Path(args.output_dir) / args.environment
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Load values
    print(f"Loading values for environment: {args.environment}")
    values = load_values(args.environment)
    
    # Setup Jinja2 environment
    template_dir = Path('kubernetes/templates')
    env = Environment(
        loader=FileSystemLoader(template_dir),
        autoescape=select_autoescape(['html', 'xml']),
        trim_blocks=True,
        lstrip_blocks=True
    )
    
    # Add custom filters
    env.filters['b64encode'] = lambda s: base64.b64encode(s.encode()).decode()
    
    print(f"Rendering templates to {output_dir}")
    
    rendered_files = []
    
    # Render PostgreSQL StatefulSet
    print("Rendering PostgreSQL resources...")
    context = {
        'namespace': values['namespace'],
        'environment': values['environment'],
        'postgres': values['postgres']
    }
    rendered_files.append(render_template(env, 'postgres-statefulset.j2', context, output_dir))
    
    # Render Python service
    print("Rendering Python service resources...")
    context = {**values, **values['python_service']}
    rendered_files.append(render_template(env, 'deployment.j2', context, output_dir))
    rendered_files.append(render_template(env, 'service.j2', context, output_dir))
    
    # Render Node.js service
    print("Rendering Node.js service resources...")
    context = {**values, **values['nodejs_service']}
    rendered_files.append(render_template(env, 'deployment.j2', context, output_dir))
    rendered_files.append(render_template(env, 'service.j2', context, output_dir))
    
    # Render Ingress if enabled
    if values.get('ingress', {}).get('enabled', False):
        print("Rendering Ingress...")
        context = {
            'namespace': values['namespace'],
            'environment': values['environment'],
            'ingress_name': values['ingress']['name'],
            'ingress_host': values['ingress']['host'],
            'services': values['ingress']['services']
        }
        rendered_files.append(render_template(env, 'ingress.j2', context, output_dir))
    
    print(f"\n✅ Successfully rendered {len(rendered_files)} manifests to {output_dir}")
    
    # Create kustomization.yaml for easy deployment
    kustomization = {
        'apiVersion': 'kustomize.config.k8s.io/v1beta1',
        'kind': 'Kustomization',
        'resources': [f.name for f in rendered_files]
    }
    
    kustomization_path = output_dir / 'kustomization.yaml'
    with open(kustomization_path, 'w') as f:
        yaml.dump(kustomization, f, default_flow_style=False)
    
    print(f"✅ Created kustomization.yaml for easy deployment")

if __name__ == '__main__':
    main()