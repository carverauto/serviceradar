import {Layer} from '@deck.gl/core';

class MyLayer extends Layer {
  draw(opts) {
     console.log(opts.uniforms);
  }
}

const layer = new MyLayer();
// simulate deck.gl calling draw
layer.draw({ uniforms: { } });
