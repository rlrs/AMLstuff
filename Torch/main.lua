require('pl')
require('torch')
require('nn')
require('gnuplot')

include('BinaryRAE.lua')
include('util.lua')
include('Vocab.lua')

torch.setnumthreads(8)
cmd = torch.CmdLine()
cmd:text()
cmd:option('-train', false,               'train the model (true/false)')
cmd:option('-draw',  false, 'draw matrices')
cmd:option('-q',     false,  'query')
cmd:option('-tsne',  false,               'run t-sne on corpus')
params = cmd:parse(arg)

local emb_dim = 50
local model = BinaryRAE(emb_dim)
if path.isfile('model.th') then
   model = torch.load('model.th')
end

-- load vocab & word embeddings
local vocab = Vocab('vocab.th')
vocab:add_unk_token()
local emb_vecs = torch.load('vectors.50d.th')
local emb = nn.LookupTable(emb_vecs:size(1), emb_vecs:size(2))
emb.weight:copy(emb_vecs)

-- load corpus - TODO: Handle UNK???
local train_dir = '../data'
local corpus, labels = load_corpus(train_dir, vocab, emb)

-- train
if params.train then
   local num_epochs = 50
   local save_epochs = 5
   local costs = torch.Tensor(num_epochs)
   for i = 1, num_epochs do
      local cost = 0
      local count = 0
      model:resetGrad()
      for d = 1, #corpus do
         local doc = corpus[d]
         for s = 1, #doc do
            count = count + 1
            local tree = leaf_tree(doc[s])
            cost = cost + model:accGrad(tree)
         end
      end
      costs[i] = cost / count
      model:train(cost)
      --local tree = leaf_tree("the cat sat", vocab, emb)
      --costs[i] = model:train(tree)
      print("Cost at iteration " .. i .. " is " .. costs[i])
      if i % save_epochs == 0 then
         torch.save('model_' .. i .. '.th', model)
      end
   end

   torch.save('model.th', model)
   gnuplot.plot(costs)
elseif params.draw then
   -- encoder weights
   gnuplot.figure(2)
   gnuplot.imagesc(model.encoder:parameters()[1], 'color')

   -- decoder weights
   gnuplot.figure(3)
   gnuplot.imagesc(model.decoder:parameters()[1], 'color')
elseif params.tsne then
   -- build corpus vectors
   local num_doc = #corpus
   local vecs = {}
   local tsne_labels = {}
   local count = 1
   for d = 1, num_doc do
      local doc = corpus[d]
      vecs[d] = torch.Tensor(#doc, 50)
      for s = 1, #doc do
         local root = model:forward(leaf_tree(doc[s]))
         local vec = root.value:clone()

         vecs[d][s] = vec

         tsne_labels[count] = labels[count][1]
         count = count + 1
      end
   end

   -- run t-sne on corpus
   local function show_scatter_plot(mapped_x, tsne_labels, opts)

     -- count label sizes:
     local K = 0
     local cnts = torch.zeros(21)
     local keys_id = {}
     for _,l in ipairs(tsne_labels) do
        if not keys_id[l] then
           K = K + 1
           keys_id[l] = K
           cnts[K] = 1
        else
           local key = keys_id[l]
           cnts[key] = cnts[key] + 1
        end
     end
     print(K)

     -- Get inverse keys_id table
     local id_keys = {}
     for k,v in pairs(keys_id) do
        id_keys[v] = k
     end

     -- separate mapped data per label:
     mapped_data = {}
     for k = 1, K do
       mapped_data[k] = { key = id_keys[k], values = torch.Tensor(cnts[k], opts.ndims) }
     end
     local offset = torch.Tensor(K):fill(1)
     for n,l in ipairs(tsne_labels) do
        local key = keys_id[l]
        mapped_data[key].values[offset[key]]:copy(mapped_x[n])
        offset[key] = offset[key] + 1
     end

     -- show results in scatter plot:
     local gfx = require 'gfx.js'
     gfx.chart(mapped_data, {
        chart = 'scatter',
        width = 1600,
        height = 900,
     })
   end
   local manifold = require('manifold')
   local opts = {ndims = 3, perplexity = 30, pca = 100, use_bh = true}
   vecs = torch.concat(vecs)
   local mapped = manifold.embedding.tsne(vecs, opts)
   show_scatter_plot(mapped, tsne_labels, opts)

   -- save mappings to matlab file
   local mattorch = require('fb.mattorch')
   mattorch.save('tsne.mat', mapped)

else
   -- load or build corpus vectors
   local vecs = {}
   if path.isfile('corpus_vecs.th') then
      vecs = torch.load('corpus_vecs.th')
   else
      local num_doc = #corpus
      local count = 1
      for d = 1, num_doc do
         local doc = corpus[d]
         vecs[d] = {}
         for s = 1, #doc do
            local root = model:forward(leaf_tree(doc[s]))
            local vec = root.value:clone()

            vecs[d][s] = vec

            count = count + 1
         end
      end

      -- Save in Torch serialized format
      torch.save('corpus_vecs.th', vecs)

      -- Save in numpy format (for Python classifier)
      local py = require('fb.python')
      py.exec([=[
import numpy as np
f = open('corpus_vecs.npy', 'w+')
np.save(f, vecs)
f = open('corpus_labels.npy', 'w+')
np.save(f, labels)
      ]=], {vecs = vecs, labels = labels})
   end

   local q = leaf_tree_str(params.q, vocab, emb)
   local vec = model:forward(q).value

   local count = 0
   local sorted = {}
   local last_best = -math.huge
   while #sorted < 5 do
      local best_cost = math.huge
      local best_d = 0
      local best_s = 0
      for d, doc in ipairs(vecs) do
         for s, svec in ipairs(doc) do
            --local cost = torch.dot(svec, vec) / (torch.norm(svec, 2) * torch.norm(vec, 2))
            local cost = torch.norm(svec - vec, 2)
            if cost < best_cost and cost > last_best then
               best_cost = cost
               best_d = d
               best_s = s
            end
         end
      end

      sorted[count] = {best_d, best_s, best_cost}
      last_best = best_cost
      count = count + 1
   end

   for i,v in ipairs(sorted) do
      print(i, v[3], v[2], labels[v[1]])
   end
end
