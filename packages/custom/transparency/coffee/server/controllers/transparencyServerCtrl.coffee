'use strict'

qfs = require 'q-io/fs'
fs = require 'fs'
config = require('meanio').loadConfig()
mongoose = require 'mongoose'
iconv = require 'iconv-lite'
_ = require 'lodash'
#mongooseWhen = require 'mongoose-when'
Q = require 'q'
#Promise = mongoose.Promise

#iconv.extendNodeEncodings()

Transfer = mongoose.model 'Transfer'

regex = /"?(.+?)"?;(\d{4})(\d);(\d{1,2});\d;"?(.+?)"?;(\d+(?:,\d{1,2})?).*/

lineToTransfer = (line, feedback) ->
    m = line.match regex
    #console.log "Result: #{m} for line #{line}"
    if m
        transfer = new Transfer()
        transfer.organisation = m[1].replace '""','"'
        transfer.year = parseInt m[2]
        transfer.quarter = parseInt m[3]
        transfer.transferType = parseInt m[4]
        transfer.media = m[5].replace '""','"'
        transfer.period = m[3] + m[2]
        transfer.amount = parseFloat m[6].replace ',', '.'
        transfer.save()
        feedback.quarter = transfer.quarter
        feedback.year = transfer.year
        feedback.entries++
        feedback.paragraph2++ if transfer.transferType is 2
        feedback.paragraph4++ if transfer.transferType is 4
        feedback.paragraph31++ if transfer.transferType is 31
        feedback.sumParagraph2 += transfer.amount if transfer.transferType is 2
        feedback.sumParagraph4 += transfer.amount if transfer.transferType is 4
        feedback.sumParagraph31 += transfer.amount if transfer.transferType is 31
        feedback.sumTotal += transfer.amount
    feedback

module.exports = (Transparency) ->

    overview: (req, res) ->
        queryPromise = Transfer.aggregate({$match: {}})
        .group(
            _id:
                quarter: "$quarter"
                year: "$year"
                transferType: "$transferType"
            entries: {$sum: 1}
            total:
                $sum: "$amount")
        .project(quarter: "$_id.quarter", year: "$_id.year", transferType: "$_id.transferType", _id: 0, entries: 1, total: 1)
        #.sort('-year -quarter transferType')
        .group(
            _id:
                year: "$year"
            quarters:
                $addToSet: {quarter: "$quarter", transferType: "$transferType", entries: "$entries", total: "$total"}
            total:
                $sum: "$total")
        .project(year: "$_id.year", _id: 0, quarters: 1, total: 1)
        .sort("-year")
        .exec()
        queryPromise.then(
            (result) ->
                res.send result
            (err) ->
                res.status(500).send "Could not load overview from Database: #{err}"
        )

    years: (req, res) ->
        queryPromise = Transfer.aggregate($match: {})
        .group(_id:
            year: "$year")
        .project(year: "$_id.year", _id: 0)
        .sort("-year")
        .exec()
        queryPromise.then(
            (result) ->
                res.send years: result.map (e)->
                    e.year
            (err) ->
                res.status(500).send "Could not load overview from Database: #{err}"
        )

    upload: (req, res) ->
        file = req.files.file;
        feedback =
            quarter: 0
            year: 0
            entries: 0
            paragraph2: 0
            sumParagraph2: 0
            paragraph4: 0
            sumParagraph4: 0
            paragraph31: 0
            sumParagraph31: 0
            sumTotal: 0.0
        #qfs.read(file.path).then(
        fs.readFile file.path, (err,data) ->
            if err
                res.send 500, "Error #{err.message}"
            else
                input = iconv.decode data,'latin1'
                feedback = lineToTransfer line, feedback for line in input.split('\n')
                res.send feedback

    periods: (req, res) ->
        Transfer.aggregate(
            $match: {}
        )
        .group(
            _id:
                year: "$year", quarter: "$quarter", period: "$period"
        )
        .project(
            year: "$_id.year", quarter: "$_id.quarter", period: "$_id.period", _id: 0
        )
        .sort("-year -quarter")
        .exec()
        .then(
            (data) ->
                res.send data
            (err) -> res.status(500).send("Could not load periods (#{err})!")
        )


    flows: (req, res) ->
        maxLength = parseInt req.query.maxLength or "750"
        years = req.query.years or []
        years = [years] if years not instanceof Array
        quarters = req.query.quarters or []
        quarters = [quarters] if quarters not instanceof Array
        paymentTypes = req.query.pType or []
        paymentTypes = [paymentTypes] if paymentTypes not instanceof Array
        orgType = req.query.orgType or 'org'
        name = req.query.name
        query = {}
        (query.year =
            $in: years.map (e)->
                parseInt(e)) if years.length > 0
        (query.quarter =
            $in: quarters.map (e)->
                parseInt(e)) if quarters.length > 0
        (query.transferType =
            $in: paymentTypes.map (e)->
                parseInt(e)) if paymentTypes.length > 0
        query[if orgType is 'org' then 'organisation' else 'media'] = name if name
        if req.query.filter
            filter = req.query.filter
            query.$or = [
                {organisation: { $regex: ".*#{filter}.*", $options: "i"}}
                {media: { $regex: ".*#{filter}.*", $options: "i"}}
            ]
        group =
            _id:
                organisation: "$organisation"
                transferType: "$transferType"
                media: "$media"
            amount:
                $sum: "$amount"
        Transfer.aggregate($match: query)
        .group(group)
        .project(
                organisation: "$_id.organisation"
                transferType: "$_id.transferType",
                media: "$_id.media"
                _id: 0
                amount: 1)
        .exec()
        .then (result) ->
            if result.length > maxLength
                res.status(413).send {
                    error: "You query returns more then the specified maximum od #{maxLength}"
                    length: result.length
                }
            else
                res.json result
        .onReject (err) ->
            res.status(500).send error: "Could not load money flow"


    topEntries: (req, res) ->
        years = req.query.years or []
        years = [years] if years not instanceof Array
        quarters = req.query.quarters or []
        quarters = [quarters] if quarters not instanceof Array
        orgType = req.query.orgType or 'org'
        paymentTypes = req.query.pType or ['2']
        paymentTypes = [paymentTypes] if paymentTypes not instanceof Array
        results = parseInt(req.query.x or '10')
        query = {}
        (query.year =
            $in: years.map (e)->
                parseInt(e)) if years.length > 0
        (query.quarter =
            $in: quarters.map (e)->
                parseInt(e)) if quarters.length > 0
        query.transferType =
            $in: paymentTypes.map (e)->
                parseInt(e)
        group =
            _id: {organisation: if orgType is 'org' then '$organisation' else '$media'}
            total:
                $sum: '$amount'
        options = {}
        options.map = () ->
            emit this.year, this.amount
        options.reduce = (key, vals) ->
            Array.sum vals
        options.query = query
        #console.log "Query: "
        #console.log query
        #console.log "Group: "
        #console.log group
        topPromise = Transfer.aggregate($match: query)
        .group(group)
        .sort('-total')
        .limit(results)
        .project(
            organisation: '$_id.organisation'
            _id: 0
            total: 1
        )
        .exec()
        allPromise = Transfer.mapReduce options
        allPromise.then (r) ->
        Q.all([topPromise, allPromise])
        .then (results) ->
            try
                result =
                    top: results[0]
                    all: results[1].reduce(
                        (sum, v)->
                            sum + v.value
                        0)
                res.send result
            catch error
                console.log error
                res.status(500).send("No Data was found!")
        .catch (err) ->
            console.log "Error in Promise.when"
            console.log err
            res.status(500).send("Error #{err.message}")

    search: (req,res) ->
        name = req.query.name
        if not name
            res.status(400).send error: "'name' is required!"
            return
        types = if req.query.orgType then [req.query.orgType] else ['org','media']
        buildRegex = (name,value) ->
            q={}
            q[name]= { $regex: ".*#{value}.*", $options: "i"}
            q
        performQuery = (orgType) ->
            nameField = if orgType is 'org' then 'organisation' else 'media'
            $or = name.split(' ').reduce ((a,n)-> q={};a.push buildRegex(nameField,n);a) ,[]
            query = $or: $or
            group =
                _id:
                    name: "$#{nameField}"
                    type: orgType
                years:
                    $addToSet: "$year"
                total: $sum: "$amount"
                transferTypes: $addToSet: "$transferType"
            Transfer.aggregate($match: query)
            .group(group)
            .project(
                name: '$_id.name'
                _id: 0
                years: 1
                total: 1
                transferTypes: 1
            )
            .sort('name')
            .exec()
        all = Q.all types.map (t) ->
            performQuery t
        all.then (results) ->
            result = types.reduce ((r,t,index) -> r[t] = results[index];r),{}
            res.json result
        .catch (err) ->
            res.status(500).send error: "Could not perform search"

    list: (req,res) ->
        types = if req.query.orgType then [req.query.orgType] else ['org','media']
        page = parseInt req.query.page or "0"
        size = parseInt req.query.size or "50"
        performQuery = (orgType) ->
            nameField = if orgType is 'org' then 'organisation' else 'media'
            query = {}
            group =
                _id:
                    name: "$#{nameField}"
                    type: orgType
                years:
                    $addToSet: "$year"
                total: $sum: "$amount"
                transferTypes: $addToSet: "$transferType"
            Transfer.aggregate($match: query)
            .group(group)
            .project(
                name: '$_id.name'
                _id: 0
                years: 1
                total: 1
                transferTypes: 1
            )
            .sort('name').skip(page*size).limit(size)
            .exec()
        all = Q.all types.map (t) ->
            performQuery t
        all.then (results) ->
            result = types.reduce ((r,t,index) -> r[t] = results[index];r),{}
            res.json result
        .catch (err) ->
            res.status(500).send error: "Could not perform search #{err}"

    count: (req,res) ->
        type = req.query.orgType or 'org'
        performQuery = (orgType) ->
            nameField = if orgType is 'org' then 'organisation' else 'media'
            query = {}
            group =
                _id:
                    name: "$#{nameField}"
            Transfer.aggregate($match: query)
            .group(group)
            .exec()
        performQuery(type)
        .then (result) ->
            res.json result.length
        .onReject (err) ->
            res.status(500).send error: "Could not determine number of items #{err}"