{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE UndecidableInstances #-}

module Servant.Client.MultipartFormData
  ( ToMultipartFormData (..)
  , MultipartFormDataReqBody
  ) where

import           Control.Exception
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Except
import           Data.ByteString.Lazy       hiding (pack, filter, map, null, elem)
import           Data.Proxy
import           GHC.TypeLits
import           Data.String.Conversions
import           Data.Typeable              (Typeable)
import           Network.HTTP.Client        hiding (Proxy, path)
import qualified Network.HTTP.Client        as Client
import           Network.HTTP.Client.MultipartFormData
import           Network.HTTP.Media
import           Network.HTTP.Types
import qualified Network.HTTP.Types         as H
import qualified Network.HTTP.Types.Header  as HTTP
import           Servant.API
import           Servant.API.Verbs
import           Servant.Common.BaseUrl
import           Servant.Client
import           Servant.Common.Req

import           Data.ByteString.Lazy       (ByteString)
import           Data.List
import           Data.Text                  (unpack)
import           Network.HTTP.Client        (Manager, Response)
import           Servant.Client.Experimental.Auth
import           Servant.Common.BasicAuth

-- | A type that can be converted to a multipart/form-data value.
class ToMultipartFormData a where
  -- | Convert a Haskell value to a multipart/form-data-friendly intermediate type.
  toMultipartFormData :: a -> [Part]

-- | Extract the request body as a value of type @a@.
data MultipartFormDataReqBody a
    deriving (Typeable)

instance (ToMultipartFormData b, MimeUnrender ct a, cts' ~ (ct ': cts)
  ) => HasClient (MultipartFormDataReqBody b :> Post cts' a) where
  type Client (MultipartFormDataReqBody b :> Post cts' a)
    = b -> Manager -> BaseUrl -> ClientM a
  clientWithRoute Proxy req reqData manager baseurl =
    let reqToRequest' req' baseurl' = do
          requestWithoutBody <- reqToRequest req' baseurl'
          formDataBody (toMultipartFormData reqData) requestWithoutBody
    in snd <$> performRequestCT' reqToRequest' (Proxy :: Proxy ct) H.methodPost req manager baseurl

-- copied `performRequest` from servant-0.7.1, then modified so it takes a variant of `reqToRequest`
-- as an argument.
performRequest' :: (Req -> BaseUrl -> IO Request)
               -> Method -> Req -> Manager -> BaseUrl
               -> ClientM ( Int, ByteString, MediaType
                          , [HTTP.Header], Response ByteString)
performRequest' reqToRequest' reqMethod req manager reqHost = do
  partialRequest <- liftIO $ reqToRequest req reqHost

  let request = partialRequest { Client.method = reqMethod
                               , checkStatus = \ _status _headers _cookies -> Nothing
                               }

  eResponse <- liftIO $ catchConnectionError $ Client.httpLbs request manager
  case eResponse of
    Left err ->
      throwE . ConnectionError $ SomeException err

    Right response -> do
      let status = Client.responseStatus response
          body = Client.responseBody response
          hdrs = Client.responseHeaders response
          status_code = statusCode status
      ct <- case lookup "Content-Type" $ Client.responseHeaders response of
                 Nothing -> pure $ "application"//"octet-stream"
                 Just t -> case parseAccept t of
                   Nothing -> throwE $ InvalidContentTypeHeader (cs t) body
                   Just t' -> pure t'
      unless (status_code >= 200 && status_code < 300) $
        throwE $ FailureResponse status ct body
      return (status_code, body, ct, hdrs, response)

-- copied `performRequestCT` from servant-0.7.1, then modified so it takes a variant of `reqToRequest`
-- as an argument.
performRequestCT' :: MimeUnrender ct result =>
  (Req -> BaseUrl -> IO Request) ->
  Proxy ct -> Method -> Req -> Manager -> BaseUrl
    -> ClientM ([HTTP.Header], result)
performRequestCT' reqToRequest' ct reqMethod req manager reqHost = do
  let acceptCT = contentType ct
  (_status, respBody, respCT, hdrs, _response) <-
    performRequest' reqToRequest' reqMethod (req { reqAccept = [acceptCT] }) manager reqHost
  unless (matches respCT (acceptCT)) $ throwE $ UnsupportedContentType respCT respBody
  case mimeUnrender ct respBody of
    Left err -> throwE $ DecodeFailure err respCT respBody
    Right val -> return (hdrs, val)