# RemoteStore
# ============

# Connection / Socket to our couch
#
# RemoteStore is using CouchDB's `_changes` feed to listen to changes
# and `_bulk_docs` to push local changes
#
# When hoodie.my.remote is continuously syncing (default), it will continuously 
# synchronize, otherwise sync, pull or push can be called manually
#
class Hoodie.AccountRemoteStore extends Hoodie.RemoteStore

  # properties
  # ------------

  # sync by default
  _sync: true


  # Constructor
  # -------------

  #
  constructor : (@hoodie, options = {}) ->
    # set name to user's DB name
    @name = @hoodie.my.account.db()
    
    # overwrite default with _remote.sync config, if set
    @_sync = @hoodie.my.config.get('_remote.sync') if @hoodie.my.config.get('_remote.sync')?

    super
    

  # Connect
  # ---------

  # do not start to sync immediately, but authenticate beforehand
  # 
  connect : =>
    @hoodie.my.account.authenticate().pipe => super


  # disconnect
  # ------------

  # 
  disconnect: ->
    # binding comes from @sync
    @hoodie.unbind 'store:idle',   @push

    super
  

  # startSyncing
  # --------------

  # start continuous syncing with current users store
  # 
  startSyncing : =>
    @hoodie.my.config.set '_remote.sync', true

    @hoodie.on 'account:signin',     @_handleSignIn
    @hoodie.on 'account:signout',    @disconnect

    super


  # stopSyncing
  # -------------

  # stop continuous syncing with current users store
  # 
  stopSyncing : =>
    @hoodie.my.config.set '_remote.sync', false

    @hoodie.unbind 'account:signin',  @_handleSignIn
    @hoodie.unbind 'account:signout', @disconnect

    super


  # sync
  # ------

  # 
  sync : (docs) =>
    if @isContinuouslyPushing()
      @hoodie.unbind 'store:idle', @push
      @hoodie.on     'store:idle', @push

    super
    

  # get and set since nr
  # ----------------------

  # we store the last since number from the current user's store
  # in his config
  # 
  getSinceNr : (since) ->
    @hoodie.my.config.get('_remote.since') or 0
  setSinceNr : (since) ->
    @hoodie.my.config.set('_remote.since', since)


  # push
  # ------

  # if no docs passed to be pushed, we default to users changed objects
  # in his store
  push : (docs) =>
    docs = @hoodie.my.store.changedDocs() unless $.isArray docs
    promise = super(docs)


  # Events
  # --------

  # namespaced alias for `hoodie.on`
  # 
  on  : (event, cb) -> 
    event = event.replace /(^| )([^ ]+)/g, "$1remote:$2"
    @hoodie.on  event, cb
  one : (event, cb) -> 
    event = event.replace /(^| )([^ ]+)/g, "$1remote:$2"
    @hoodie.one event, cb
  
  # namespaced alias for `hoodie.trigger`
  # 
  trigger : (event, parameters...) -> 
    @hoodie.trigger "remote:#{event}", parameters...


  # Private
  # ---------

  # 
  _handleSignIn: =>
    @name = @hoodie.my.account.db()
    @connect()

  # update local _rev attributes after changes pushed
  _handlePushSuccess: (docs, pushedDocs) =>
    =>
      for doc, i in docs
        update  = {_rev: pushedDocs[i]._rev}
        options = remote : true
        @hoodie.my.store.update(doc.$type, doc.id, update, options) 

  # 
  _handlePullResults : (changes) =>
    _destroyedDocs = []
    _changedDocs   = []
    
    # 1. update or remove objects from local store
    for {doc} in changes
      doc = @_parseFromRemote(doc)
      if doc._deleted
        _destroyedDocs.push [doc, @hoodie.my.store.destroy( doc.$type, doc.id,      remote: true)]
      else                                                
        _changedDocs.push   [doc, @hoodie.my.store.save(    doc.$type, doc.id, doc, remote: true)]
    
    # 2. trigger events
    for [doc, promise] in _destroyedDocs
      promise.then (object) => 
        @trigger 'destroy',                        object
        @trigger "destroy:#{doc.$type}",           object
        @trigger "destroy:#{doc.$type}:#{doc.id}", object
        
        @trigger 'change',                         'destroy', object
        @trigger "change:#{doc.$type}",            'destroy', object
        @trigger "change:#{doc.$type}:#{doc.id}",  'destroy', object
    
    for [doc, promise] in _changedDocs
      promise.then (object, objectWasCreated) => 
        event = if objectWasCreated then 'create' else 'update'
        @trigger event,                             object
        @trigger "#{event}:#{doc.$type}",           object
        @trigger "#{event}:#{doc.$type}:#{doc.id}", object unless event is 'create'
      
        @trigger "change",                          event, object
        @trigger "change:#{doc.$type}",             event, object
        @trigger "change:#{doc.$type}:#{doc.id}",   event, object unless event is 'create'