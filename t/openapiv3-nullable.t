use Mojo::Base -strict;
use JSON::Validator;
use Test::More;

my $schema = JSON::Validator->new->schema('data://main/spec.json')->schema;
my ($body, @errors);

for my $path (qw(/nullable-data /nullable-ref)) {
  $body   = {exists => 1, value => {id => 42}};
  @errors = $schema->validate_response([get => $path], {body => \&body});
  is "@errors", "/body/name: Missing property.", "$path - missing name";

  $body   = {exists => 1, value => {id => 42, name => undef}};
  @errors = $schema->validate_response([get => $path], {body => \&body});
  is "@errors", "", "$path - name is undef";
}

done_testing;

sub body {$body}

__DATA__
@@ spec.json
{
  "openapi": "3.0.0",
  "info": { "title": "Nullable", "version": "" },
  "paths": {
    "/nullable-data": {
      "get": {
        "responses": {
          "200": {
            "content": { "application/json": { "schema": {"$ref": "#/components/schemas/WithNullable"} } }
          }
        }
      }
    },
    "/nullable-ref": {
      "get": {
        "operationId": "withNullableRef",
        "responses": {
          "200": {
            "content": { "application/json": { "schema": {"$ref": "#/components/schemas/WithNullableRef"} } }
          }
        }
      }
    }
  },
  "components": {
    "schemas": {
      "WithNullable": {
        "required": [ "id", "name" ],
        "properties": {
          "id": { "type": "integer", "format": "int64" },
          "name": { "type": "string", "nullable": true }
        }
      },
      "WithNullableRef": {
        "required": [ "id", "name" ],
        "properties": {
          "id": { "type": "integer", "format": "int64" },
          "name": { "$ref": "#/components/schemas/WithNullable/properties/name" }
        }
      }
    }
  }
}
