###
#
# BelongsTo 'user', User
#     leads to
#     user: -> @belongsTo User
#
# BelongsTo User
#     leads to
#     <User.name.toLowerCase()>: -> @belongsTo User
#
# BelongsTo 'user', User, -> @where(username: 'foo')
#     leads to
#     user: -> relation = @belongsTo(User); f.call(relation)
#
# class User extends db.Model
#     tableName: 'users'
#     @schema [
#         HasMany Photo
#     ]
#
# class Photo extends db.Model
#     tableName: 'photos'
#     @schema [
#         BelongsTo User
#     ]
#
# Photo.forge(id: 1).fetch(withRelated: 'user').then (photo) ->
#     photo.user                              # function
#     photo.related('user')                   # Model
#     photo.$user                             # Collection
#     photo.$user = user                      # set user_id to user.id
#     photo.$user.assign(user)                # set user_id to user.id and save
#
# User.forge(id: 1).fetch(withRelated: 'photos').then (user) ->
#     user.photos                             # function
#     user.related('photos')                  # Collection
#     user.$photos                            # Collection
#     user.$photos = [...]                    # detach all photos and attach listed
#     user.$photos.assign(...)                # detach all photos and attach listed
#     user.$photos.attach(...)                # attach listed photos and save them
#     user.$photos.detach(...)                # detach listed photos
#
# class User extends db.Model
#     tableName: 'users'
#     @schema [
#         HasMany Photo, onDestroy: (cascade|cascade direct|detach|detach direct|reject|ignore)
#     ]
#
###

pluralize = require 'pluralize'
{IntField} = require './fields'
{Fulfilled, Rejected} = require './utils'

pluck = (obj, fields...) ->
    return {} unless obj?
    result = {}
    for f in fields when f of obj
        result[f] = obj[f]
    result

upperFirst = (str) -> str[0].toUpperCase() + str[1..]

values = (obj) -> v for k, v of obj

notNull = (a) -> a?

cast =
    forgeOrFetch: (self, obj, msg) ->
        model = self.model or self.constructor
        switch
            when obj is null
                Fulfilled null
            when typeof obj is 'number'
                model.forge(id: obj).fetch()
            when obj.constructor is Object
                Fulfilled model.forge(obj)
            when obj instanceof model
                Fulfilled obj
            else
                throw new Error msg

    saveOrFetch: (self, obj, options, msg) ->
        model = self.model or self.constructor
        switch
            when obj is null
                Fulfilled {id: null}
            when typeof obj is 'number'
                model.forge(id: obj).fetch(options)
            when obj.constructor is Object
                model.forge(obj).save(options)
            when obj instanceof model
                Fulfilled obj
            else
                throw new Error msg

# Originally posted by @nathggns at https://github.com/tgriesser/bookshelf/issues/126
fixedCount = (object) ->
    sync = object.sync()

    relatedData = sync.syncing.relatedData
    if relatedData.isJoined()
        relatedData.joinClauses sync.query
    relatedData.whereClauses sync.query

    sync.query.count('*')
    .then (result) ->
        throw new Error('Empty response') if !result
        Number values(result[0])[0]

class Relation
    @multiple: false

    constructor: (model, options = {}) ->
        return new Relation(arguments...) unless this instanceof Relation
        @relatedModel = model
        @options = options
        @name = @_deduceName(@relatedModel)

    pluginOption: (name, defaultVal) -> @model.__bookshelf_schema_options[name] or defaultVal
    option: (name, pluginOptionName, defaultVal) ->
        if arguments.length is 2
            defaultVal = pluginOptionName
            pluginOptionName = name
        value = @options[name]
        value = @pluginOption(pluginOptionName, defaultVal) unless value?
        value
    contributeToSchema: (schema) -> schema.push this
    contributeToModel: (cls) ->
        @model = cls
        @accessor = @options.accessor || @_deduceAccessorName(@name)
        cls::[@name] = @createRelation(cls) unless @name of cls.prototype
        if @option('createProperty', 'createProperties', true)
            @_createProperty(cls)

    createRelation: (cls) ->
        relation = @_createRelation(cls)
        relation = @_applyQuery(relation)
        relation = @_applyThrough(relation)

        self = this
        -> self._augementRelated this, relation.apply(this, arguments)

    createGetter: ->
        self = this
        ->
            related = @related(self.name)
            unless related.__augemented
                self._augementRelated this, related
            related

    createSetter: ->

    # TODO: apply withPivot
    # TODO: auto-discover withPivot columns from through models schema
    _applyThrough: (builder) ->
        return builder unless @options.through
        interim = @options.through
        throughForeignKey = @options.throughForeignKey
        otherKey = @options.otherKey
        -> builder.call(this).through(interim, throughForeignKey, otherKey)

    _applyQuery: (builder) ->
        return builder unless @options.query
        query = @options.query
        -> query.apply builder.call(this)

    _augementRelated: (parent, related) ->
        return related unless @constructor.helperMethods
        self = this
        for name, method of @constructor.helperMethods
            do (method) ->
                if name of related
                    related["_original#{upperFirst(name)}"] = related[name]
                related[name] = (args...) ->
                    args = [parent, self].concat args
                    method.apply this, args
        related.__augemented = true
        related

    _createProperty: (cls) ->
        return if @name is 'id' or @accessor of cls.prototype
        spec = {}
        getter = @createGetter()
        setter = @createSetter()
        spec.get = getter if getter
        spec.set = setter if setter

        Object.defineProperty cls.prototype, @accessor, spec

    _deduceName: ->
        return @options.name if @options.name?
        if @constructor.multiple
            pluralize @relatedModel.name.toLowerCase()
        else
            @relatedModel.name.toLowerCase()

    _deduceAccessorName: -> "#{@pluginOption('relationAccessorPrefix', '$')}#{@name}"

class HasOne extends Relation
    constructor: (model, options = {}) ->
        return new HasOne(arguments...) unless this instanceof HasOne
        super

    @helperMethods:
        # TODO: allow assignment with interim model
        assign: (model, relation, obj, options) ->
            if relation.options.through
                return Rejected new Error "Can't assign relation with interim model"
            options = pluck options, 'transacting'
            foreignKey = @relatedData.key 'foreignKey'

            try
                obj = cast.forgeOrFetch this, obj, "Can't assign #{obj} to #{model} as a #{relation.name}"
                old = model[relation.name]().fetch()

                Promise.all([old, obj]).then ([old, obj]) ->
                    pending = []
                    if old.id?
                        old = old.clone() # force knex not to use relatedData
                        pending.push old.save(foreignKey, null, options)
                    if obj?
                        obj.set(foreignKey, model.id)
                        pending.push obj.save(options)
                    Promise.all pending
            catch e
                Rejected e

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @hasOne related, foreignKey

class BelongsTo extends Relation
    constructor: (model, options = {}) ->
        return new BelongsTo(arguments...) unless this instanceof BelongsTo
        super

    contributeToSchema: (schema) ->
        super
        schema.push IntField "#{@name}_id"

    @helperMethods:
        # TODO: allow assignment with interim model
        assign: (model, relation, obj, options) ->
            if relation.options.through
                return Rejected new Error "Can't assign relation with interim model"
            options = pluck options, 'transacting'
            foreignKey = @relatedData.key 'foreignKey'

            try
                related = cast.saveOrFetch this, obj, options, "Can't assign #{obj} to #{model} as a #{relation.name}"
                related.then (related) -> model.save(foreignKey, related.id, options)
            catch e
                Rejected e

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @belongsTo related, foreignKey

    # Patch returned relations joinClauses and whereClauses
    # TODO: apply withPivot
    # TODO: auto-discover withPivot columns from through models schema
    _applyThrough: (builder) ->
        return builder unless @options.through
        interim = @options.through
        throughForeignKey = @options.throughForeignKey
        otherKey = @options.otherKey
        ->
            relation = builder.call(this).through(interim, throughForeignKey, otherKey)
            relation.relatedData.joinClauses = BelongsTo._patchedJoinClauses
            relation.relatedData.whereClauses = BelongsTo._patchedWhereClauses
            relation

    @_patchedJoinClauses: (knex) ->
        joinTable = @joinTable()
        targetKey = @key('foreignKey')

        knex.join \
            joinTable,
            joinTable + '.' + targetKey, '=',
            @targetTableName + '.' + @targetIdAttribute

        knex.join \
            "#{@parentTableName} as __parent",
            "#{joinTable}.#{@throughIdAttribute}", '=',
            "__parent.#{@key('throughForeignKey')}"

    @_patchedWhereClauses: (knex, resp) ->
        key = "__parent.#{@parentIdAttribute}"
        knex[if resp then 'whereIn' else 'where'](key, if resp then @eagerKeys(resp) else @parentFk)

class HasMany extends Relation
    @multiple: true

    constructor: (model, options = {}) ->
        return new HasMany(arguments...) unless this instanceof HasMany
        super

    @helperMethods:
        count: (model, relation) -> fixedCount this

        # TODO: allow assignment with interim model
        assign: (model, relation, list, options) ->
            if relation.options.through
                return Rejected new Error "Can't assign relation with interim model"
            list ?= []
            list = [list] unless list instanceof Array
            options = pluck options, 'transacting'

            try
                currentObjs = model[relation.name]().fetch()
                attachObjs  = Promise.all \
                    list.map( (obj) =>
                        cast.forgeOrFetch this, obj, "Can't assign #{obj} to #{model} as a #{relation.name}"
                    ).filter(notNull)

                Promise.all([currentObjs, attachObjs]).then ([currentObjs, attachObjs]) =>
                    currentObjs = currentObjs.models

                    idx = currentObjs.reduce (memo, obj) ->
                        memo[obj.id] = obj
                        memo
                    , {}

                    attachObj = for obj in attachObjs
                        continue unless obj.id
                        if idx[obj.id]
                            delete idx[obj.id]
                            continue
                        else
                            obj

                    detachObjs = (obj for k, obj of idx)

                    @detach(detachObjs, options).then => @attach(attachObjs, options)
            catch e
                Rejected e

        attach: (model, relation, list, options) ->
            return unless list?
            list = [list] unless list instanceof Array
            options = pluck options, 'transacting'
            try
                unloaded = []
                created = []
                models = []
                for obj in list
                    switch
                        when typeof obj is 'number'
                            unloaded.push obj
                        when obj.constructor is Object
                            created.push @model.forge(obj)
                        when obj instanceof @model
                            models.push obj
                        else
                            throw new Error("Can't attach #{obj} to #{model} as a #{relation.name}")

                loadUnloaded = if unloaded.length is 0
                    Fulfilled @model.collection()
                else
                    @model.collection().where(@model.idAttribute, 'in', unloaded).fetch()

                loadUnloaded.then (unloaded) =>
                    unloaded = unloaded.models
                    pending = for obj in unloaded.concat(created, models)
                        @_attachOne obj, options
                    Promise.all pending
            catch e
                Rejected e

        _attachOne: (model, relation, obj, options) ->
            obj.set(@relatedData.key('foreignKey'), model.id).save(options)

        detach: (model, relation, list, options) ->
            return unless list?
            list = [list] unless list instanceof Array
            options = pluck options, 'transacting'
            try
                unloaded = []
                models = []
                for obj in list
                    switch
                        when typeof obj is 'number'
                            unloaded.push obj
                        when obj instanceof @model
                            models.push obj
                        else
                            throw new Error("Can't detach #{obj} from #{model} #{relation.name}")

                loadUnloaded = if unloaded.length is 0
                    Fulfilled @model.collection()
                else
                    @model.collection().where(@model.idAttribute, 'in', unloaded).fetch()

                loadUnloaded.then (unloaded) =>
                    unloaded = unloaded.models
                    pending = for obj in unloaded.concat(models)
                        @_detachOne obj, options
                    Promise.all pending
            catch e
                Rejected e

        _detachOne: (model, relation, obj, options) ->
            obj.set(@relatedData.key('foreignKey'), null).save(options)

    _createRelation: (cls) ->
        related = @relatedModel
        foreignKey = @options.foreignKey
        -> @hasMany related, foreignKey

class BelongsToMany extends Relation
    @multiple: true

    constructor: (model, options = {}) ->
        return new BelongsToMany(arguments...) unless this instanceof BelongsToMany
        super

    @helperMethods:
        count: HasMany.helperMethods.count
        assign: HasMany.helperMethods.assign

        attach: (model, relation, list, options) ->
            try
                unsaved = []
                other = []
                for obj in list
                    switch
                        when typeof obj is 'number'
                            other.push obj
                        when obj instanceof @model and obj.id?
                            other.push obj
                        when obj instanceof @model
                            unsaved.push obj
                        when obj.constructor is Object
                            unsaved.push @model.forge(obj)
                        else
                            throw new Error("Can't attach #{obj} to #{model} as a #{relation.name}")

                unsaved = unsaved.map( (obj) -> obj.save() )
                Promise.all(unsaved).then (saved) =>
                    @_originalAttach saved.concat(other)
            catch e
                Rejected e

    _createRelation: (cls) ->
        related = @relatedModel
        table = @options.table
        foreignKey = @options.foreignKey
        otherKey = @options.otherKey
        -> @belongsToMany related, table, foreignKey, otherKey

class MorphOne extends Relation
    constructor: (model, polymorphicName, options = {}) ->
        return new MorphOne(arguments...) unless this instanceof MorphOne
        super model, options
        @polymorphicName = polymorphicName

    @helperMethods:
        assign: (model, relation, obj, options) ->
            options = pluck options, 'transacting'
            foreignKey = @relatedData.key 'foreignKey'
            morphKey = @relatedData.key 'morphKey'
            morphValue = @relatedData.key 'morphValue'

            try
                obj = cast.forgeOrFetch this, obj, "Can't assign #{obj} to #{model} as a #{relation.name}"
                old = model[relation.name]().fetch()

                Promise.all([old, obj]).then ([old, obj]) ->
                    pending = []
                    if old.id?
                        old = old.clone() # force knex not to use relatedData
                        old.set foreignKey, null
                        old.set morphKey, null
                        pending.push old.save()
                    if obj?
                        obj.set foreignKey, model.id
                        obj.set morphKey, morphValue
                        pending.push obj.save(options)
                    Promise.all pending
            catch e
                Rejected e


    _createRelation: (cls) ->
        related = @relatedModel
        name = @polymorphicName
        columnNames = @options.columnNames
        morphValue = @options.morphValue
        -> @morphOne related, name, columnNames, morphValue

class MorphMany extends Relation
    @multiple: true

    constructor: (model, polymorphicName, options = {}) ->
        return new MorphMany(arguments...) unless this instanceof MorphMany
        super model, options
        @polymorphicName = polymorphicName

    @helperMethods:
        count: HasMany.helperMethods.count
        assign: HasMany.helperMethods.assign
        attach: HasMany.helperMethods.attach
        _attachOne: (model, relation, obj, options) ->
            obj.set @relatedData.key('foreignKey'), model.id
            obj.set @relatedData.key('morphKey'), @relatedData.key('morphValue')
            obj.save options
        detach: HasMany.helperMethods.detach
        _detachOne: (model, relation, obj, options) ->
            obj.set @relatedData.key('foreignKey'), null
            obj.set @relatedData.key('morphKey'), null
            obj.save options

    _createRelation: (cls) ->
        related = @relatedModel
        name = @polymorphicName
        columnNames = @options.columnNames
        morphValue = @options.morphValue
        -> @morphMany related, name, columnNames, morphValue

class MorphTo extends Relation
    constructor: (polymorphicName, targets, options = {}) ->
        return new MorphTo(arguments...) unless this instanceof MorphTo
        options.name = polymorphicName
        super targets, options
        @polymorphicName = polymorphicName

    @helperMethods:
        assign: (model, relation, obj, morphValue, options) ->
            unless typeof morphValue is 'string'
                options = morphValue
                morphValue = obj.tableName
            options = pluck options, 'transacting'
            foreignKey = @relatedData.key 'foreignKey'
            morphKey = @relatedData.key 'morphKey'

            model.set foreignKey, obj.id
            model.set morphKey, morphValue
            model.save(options)

    _createRelation: (cls) ->
        args = [@polymorphicName]
        args.push @options.columnNames if @options.columnNames
        args = args.concat @relatedModel
        -> @morphTo args...

module.exports =
    HasOne: HasOne
    BelongsTo: BelongsTo
    HasMany: HasMany
    BelongsToMany: BelongsToMany
    MorphOne: MorphOne
    MorphMany: MorphMany
    MorphTo: MorphTo
