-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]


-- using the full path so that we don't have to modify package.path in
-- this context
local test_vault = require "spec.fixtures.custom_vaults.kong.vaults.test"
local utils = require "kong.tools.utils"
local cjson = require "cjson"
local assert = require("luassert")


-- AWS dependencies
local aws = require "resty.aws"
local EnvironmentCredentials = require "resty.aws.credentials.EnvironmentCredentials"


-- Azure dependencies
local azure = require "resty.azure"


-- GCP dependencies
local gcp = require "resty.gcp"
local access_token = require "resty.gcp.request.credentials.accesstoken"


-- HCV dependencies
local hcv = require "kong.vaults.hcv"


--- A vault test harness is a driver for vault backends, which implements
--- all the necessary glue for initializing a vault backend and performing
--- secret read/write operations.
---
--- All functions defined here are called as "methods" (e.g. harness:fn()), so
--- it is permitted to keep state on the harness object (self).
---
---@class harness
---
---@field name string
---
--- this table is passed directly to kong.db.vaults:insert()
---@field config table
---
--- create_secret() is called once per test run for a given secret
---@field create_secret fun(self: harness, secret: string, value: string, opts?: table)
---
--- update_secret() may be called more than once per test run for a given secret
---@field update_secret fun(self: harness, secret: string, value: string, opts?: table)
----
--- delete_secret() may be called more than once per test run for a given secret
---@field delete_secret fun(self: harness, secret: string)
---
--- setup() is called before kong is started and before any DB entities
--- have been created and is best used for things like validating backend
--- credentials and establishing a connection to a backend
---@field setup fun(self: harness)
---
--- teardown() is exactly what you'd expect
---@field teardown fun(self: harness)
---
--- fixtures() output is passed directly to `helpers.start_kong()`
---@field fixtures fun(self: harness):table|nil
---
---
---@field prefix   string   # generated by the test suite
---@field host     string   # generated by the test suite


---@type harness[]
local VAULTS = {
  {
    name = "test",

    config = {
      default_value = "DEFAULT",
      default_value_ttl = 1,
    },

    create_secret = function(self, _, value)
      -- Currently, create_secret is called _before_ starting Kong.
      --
      -- This means our backend won't be available yet because it is
      -- piggy-backing on Kong as an HTTP mock fixture.
      --
      -- We can, however, inject a default value into our configuration.
      -- The test vault implementation uses the defaults just once, so that
      -- secrets can be loaded during startup.
      self.config.default_value = cjson.encode({secret = value})
    end,

    update_secret = function(_, secret, value, opts)
      return test_vault.client.put(secret, cjson.encode({secret = value}), opts)
    end,

    delete_secret = function(_, secret)
      return test_vault.client.delete(secret)
    end,

    fixtures = function()
      return {
        http_mock = {
          test_vault = test_vault.http_mock,
        }
      }
    end,
  },

  {
    name = "aws",

    config = {
      region = "us-east-1",
    },

    -- lua-resty-aws sdk object
    AWS = nil,

    -- lua-resty-aws secrets-manager client object
    sm = nil,

    -- secrets that were created during the test run, for cleanup purposes
    secrets = {},

    setup = function(self)
      assert(os.getenv("AWS_ACCESS_KEY_ID"),
             "missing AWS_ACCESS_KEY_ID environment variable")

      assert(os.getenv("AWS_SECRET_ACCESS_KEY"),
             "missing AWS_SECRET_ACCESS_KEY environment variable")

      self.AWS = aws({ credentials = EnvironmentCredentials.new() })
      self.sm = assert(self.AWS:SecretsManager(self.config))
    end,

    create_secret = function(self, secret, value, _)
      assert(self.sm, "secrets manager is not initialized")
      local res, err = self.sm:createSecret({
        ClientRequestToken = utils.uuid(),
        Name = secret,
        SecretString = cjson.encode({secret = value}),
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)

      table.insert(self.secrets, res.body.ARN)
    end,

    update_secret = function(self, secret, value, _)
      local res, err = self.sm:putSecretValue({
        ClientRequestToken = utils.uuid(),
        SecretId = secret,
        ForceDeleteWithoutRecovery = true,
        RecoveryWindowInDays = 0,
        SecretString = cjson.encode({secret = value}),
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)
    end,

    delete_secret = function(self, secret)
      local res, err = self.sm:deleteSecret({
        SecretId = secret,
      })

      assert.is_nil(err)
      assert.is_equal(200, res.status)
    end
  },

  {
    name = "azure",

    -- lua-resty-azure sdk object
    AZURE = nil,

    -- lua-resty-azure secrets-manager client object
    sm = nil,

    -- secrets that were created during the test run, for cleanup purposes
    secrets = {},

    setup = function(self)
      assert(os.getenv("AZURE_TENANT_ID"),
              "missing AZURE_TENANT_ID environment variable")

      assert(os.getenv("AZURE_CLIENT_ID"),
              "missing AZURE_CLIENT_ID environment variable")

      assert(os.getenv("AZURE_CLIENT_SECRET"),
              "missing AZURE_CLIENT_SECRET environment variable")

      local uri = assert(os.getenv("AZURE_VAULT_URI"),
              "missing AZURE_VAULT_URI environment variable")

      self.config = {
        location = "eastus",
        type = "secrets",
        vault_uri = uri,
      }

      self.AZURE = azure:new(self.config)
      self.sm = assert(self.AZURE:secrets(uri))
    end,

    create_secret = function(self, secret, value, _)
      assert(self.sm, "secrets manager is not initialized")
      local err, res
      assert
        .with_timeout(360)
        .with_step(5)
        .eventually(function()
          res, err = self.sm:create(secret, cjson.encode({secret = value}))
          if res and
             res.error and
             res.error.innererror and
             res.error.innererror.code == "ObjectIsDeletedButRecoverable" then
            -- We need to purge or recover a secret after it has been deleted.
            -- This is the azure way of accidential deletion protection.
            self.sm:purge(secret)
          end
          return err == nil and res.value ~= nil
        end).is_truthy("Could not create secret in time " .. (err or ""))
      assert.is_nil(err)
      -- assert.is_equal(res.value, value)
      assert.is_table(res.attributes)
      assert.is_true(res.attributes.enabled)
    end,

    -- Azure does not have a concept of updating a secret, you rather increment the
    -- version number of the secret by "creating" a new one
    update_secret = function(self, secret, value, _)
      self:create_secret(secret, value)
    end,

    delete_secret = function(self, secret)
      self.sm:delete(secret)
    end
  },


  {
    name = "gcp",

    GCP = nil,

    access_token = nil,

    secrets = {},

    config = {},

    setup = function(self)
      local service_account = assert(os.getenv("GCP_SERVICE_ACCOUNT"), "missing GCP_SERVICE_ACCOUNT environment variable")

      self.GCP = gcp()
      self.config.project_id = assert(cjson.decode(service_account).project_id)
      self.access_token = access_token.new()
    end,

    create_secret = function(self, secret, value, _)
      local res, err = self.GCP.secretmanager_v1.secrets.create(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretId = secret,
        },
        {
          replication = {
            automatic = {}
          }
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)

      self:update_secret(secret, value, _)

      table.insert(self.secrets, secret)
    end,

    update_secret = function(self, secret, value)
      local res, err = self.GCP.secretmanager_v1.secrets.addVersion(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretsId = secret,
        },
        {
          payload = {
            data = ngx.encode_base64(cjson.encode({secret = value})),
          }
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)
    end,

    delete_secret = function(self, secret)
      local res, err = self.GCP.secretmanager_v1.secrets.delete(
        self.access_token,
        {
          projectsId = self.config.project_id,
          secretsId = secret,
        }
      )
      assert.is_nil(err)
      assert.is_nil(res.error)
    end
  },

  -- hashi vault
  {
    name = "hcv",

    config = {
      token = "vault-plaintext-root-token",
      host = "localhost",
      port = 8200,
      kv = "v2",
    },

    create_secret = function(self, ...)
      return self:update_secret(...)
    end,

    update_secret = function(self, secret, value, _)
      local _, err = hcv._request(
        self.config,
        secret,
        nil,
        {
          method = "POST",
          body = cjson.encode({data = { secret = value }})
        })
      assert.is_nil(err)
    end,

    delete_secret = function(self, secret)
      local _, err = hcv._request(
        self.config,
        secret,
        nil,
        {
          method = "DELETE",
        })
      assert.is_nil(err)
    end
  }
}

return VAULTS
