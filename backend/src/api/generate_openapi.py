import json
import os

from src.api.main import app

def main():
    """Generate and write OpenAPI schema for the backend."""
    openapi_schema = app.openapi()
    output_dir = "interfaces"
    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, "openapi.json")
    with open(output_path, "w") as f:
        json.dump(openapi_schema, f, indent=2)
    print(f"OpenAPI written to {output_path}")

if __name__ == "__main__":
    main()
